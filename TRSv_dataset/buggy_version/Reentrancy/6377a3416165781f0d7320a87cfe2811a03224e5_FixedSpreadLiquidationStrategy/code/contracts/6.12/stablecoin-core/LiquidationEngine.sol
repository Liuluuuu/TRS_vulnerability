// SPDX-License-Identifier: AGPL-3.0-or-later

/// dog.sol -- Dai liquidation module 2.0

// Copyright (C) 2020-2021 Maker Ecosystem Growth Holdings, INC.
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity 0.6.12;

import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import "../interfaces/IBookKeeper.sol";
import "../interfaces/IAuctioneer.sol";
import "../interfaces/ILiquidationEngine.sol";
import "../interfaces/ISystemDebtEngine.sol";
import "../interfaces/ILiquidationStrategy.sol";
import "../interfaces/ICagable.sol";

/// @title LiquidationEngine
/// @author Alpaca Fin Corporation
/** @notice A contract which is the manager for all of the liquidations of the protocol.
    LiquidationEngine will be the interface for the liquidator to trigger any positions into the liquidation process.
*/

contract LiquidationEngine is
  PausableUpgradeable,
  AccessControlUpgradeable,
  ReentrancyGuardUpgradeable,
  ILiquidationEngine,
  ICagable
{
  bytes32 public constant OWNER_ROLE = DEFAULT_ADMIN_ROLE;
  bytes32 public constant GOV_ROLE = keccak256("GOV_ROLE");
  bytes32 public constant SHOW_STOPPER_ROLE = keccak256("SHOW_STOPPER_ROLE");

  struct LocalVars {
    uint256 positionLockedCollateral;
    uint256 positionDebtShare;
    uint256 debtAccumulatedRate;
    uint256 priceWithSafetyMargin;
    uint256 systemDebtEngineStablecoinBefore;
    uint256 newPositionLockedCollateral;
    uint256 newPositionDebtShare;
    uint256 wantStablecoinValueFromLiquidation;
  }

  IBookKeeper public bookKeeper; // CDP Engine

  mapping(bytes32 => address) public override strategies; // Liquidation strategy for each collateral pool

  ISystemDebtEngine public systemDebtEngine; // Debt Engine
  uint256 public live; // Active Flag

  // --- Events ---
  event SetStrategy(address indexed caller, bytes32 _collateralPoolId, address strategy);

  // --- Init ---
  function initialize(address _bookKeeper, address _systemDebtEngine) external initializer {
    PausableUpgradeable.__Pausable_init();
    AccessControlUpgradeable.__AccessControl_init();
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

    bookKeeper = IBookKeeper(_bookKeeper);
    systemDebtEngine = ISystemDebtEngine(_systemDebtEngine);

    live = 1;

    // Grant the contract deployer the owner role: it will be able
    // to grant and revoke any roles
    _setupRole(OWNER_ROLE, msg.sender);
  }

  // --- Math ---
  uint256 constant WAD = 10**18;

  function min(uint256 x, uint256 y) internal pure returns (uint256 z) {
    z = x <= y ? x : y;
  }

  function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
    require((z = x + y) >= x);
  }

  function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
    require((z = x - y) <= x);
  }

  function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
    require(y == 0 || (z = x * y) / y == x);
  }

  function setStrategy(bytes32 _collateralPoolId, address strategy) external {
    require(hasRole(OWNER_ROLE, msg.sender), "!ownerRole");
    require(live == 1, "LiquidationEngine/not-live");
    strategies[_collateralPoolId] = strategy;
    emit SetStrategy(msg.sender, _collateralPoolId, strategy);
  }

  function liquidate(
    bytes32 _collateralPoolId,
    address _positionAddress,
    uint256 _debtShareToBeLiquidated, // [rad]
    uint256 _maxDebtShareToBeLiquidated, // [rad]
    address _collateralRecipient,
    bytes calldata data
  ) external nonReentrant whenNotPaused {
    require(live == 1, "LiquidationEngine/not-live");
    require(_debtShareToBeLiquidated != 0, "LiquidationEngine/zero-debt-value-to-be-liquidated");
    require(_maxDebtShareToBeLiquidated != 0, "LiquidationEngine/zero-max-debt-value-to-be-liquidated");

    LocalVars memory vars;

    (vars.positionLockedCollateral, vars.positionDebtShare) = bookKeeper.positions(_collateralPoolId, _positionAddress);
    require(strategies[_collateralPoolId] != address(0), "LiquidationEngine/not-set-strategy");
    // 1. Check if the position is underwater
    (, vars.debtAccumulatedRate, vars.priceWithSafetyMargin, , ) = bookKeeper.collateralPools(_collateralPoolId);
    // (positionLockedCollateral [wad] * priceWithSafetyMargin [ray]) [rad]
    // (positionDebtShare [wad] * debtAccumulatedRate [ray]) [rad]
    require(
      vars.priceWithSafetyMargin > 0 &&
        mul(vars.positionLockedCollateral, vars.priceWithSafetyMargin) <
        mul(vars.positionDebtShare, vars.debtAccumulatedRate),
      "LiquidationEngine/position-is-safe"
    );

    vars.systemDebtEngineStablecoinBefore = bookKeeper.stablecoin(address(systemDebtEngine));

    ILiquidationStrategy(strategies[_collateralPoolId]).execute(
      _collateralPoolId,
      vars.positionDebtShare,
      vars.positionLockedCollateral,
      _positionAddress,
      _debtShareToBeLiquidated,
      _maxDebtShareToBeLiquidated,
      msg.sender,
      _collateralRecipient,
      data
    );

    (vars.newPositionLockedCollateral, vars.newPositionDebtShare) = bookKeeper.positions(
      _collateralPoolId,
      _positionAddress
    );
    require(vars.newPositionDebtShare < vars.positionDebtShare, "LiquidationEngine/debt-not-liquidated");

    // (positionDebtShare [wad] - newPositionDebtShare [wad]) * debtAccumulatedRate [ray]
    vars.wantStablecoinValueFromLiquidation = mul(
      sub(vars.positionDebtShare, vars.newPositionDebtShare),
      vars.debtAccumulatedRate
    ); // [rad]
    require(
      sub(bookKeeper.stablecoin(address(systemDebtEngine)), vars.systemDebtEngineStablecoinBefore) >=
        vars.wantStablecoinValueFromLiquidation,
      "LiquidationEngine/payment-not-received"
    );

    // If collateral has been depleted from liquidation whilst there is remaining debt in the position
    if (vars.newPositionLockedCollateral == 0 && vars.newPositionDebtShare > 0) {
      // Record the bad debt to the system and close the position
      bookKeeper.confiscatePosition(
        _collateralPoolId,
        _positionAddress,
        _positionAddress,
        address(systemDebtEngine),
        -int256(vars.newPositionLockedCollateral),
        -int256(vars.newPositionDebtShare)
      );
    }
  }

  function cage() external override {
    require(
      hasRole(OWNER_ROLE, msg.sender) || hasRole(SHOW_STOPPER_ROLE, msg.sender),
      "!(ownerRole or showStopperRole)"
    );
    require(live == 1, "LiquidationEngine/not-live");
    live = 0;
    emit Cage();
  }

  function uncage() external override {
    require(
      hasRole(OWNER_ROLE, msg.sender) || hasRole(SHOW_STOPPER_ROLE, msg.sender),
      "!(ownerRole or showStopperRole)"
    );
    require(live == 0, "LiquidationEngine/not-caged");
    live = 1;
    emit Uncage();
  }

  // --- pause ---
  function pause() external {
    require(hasRole(OWNER_ROLE, msg.sender) || hasRole(GOV_ROLE, msg.sender), "!(ownerRole or govRole)");
    _pause();
  }

  function unpause() external {
    require(hasRole(OWNER_ROLE, msg.sender) || hasRole(GOV_ROLE, msg.sender), "!(ownerRole or govRole)");
    _unpause();
  }
}
