// SPDX-License-Identifier: AGPL-3.0-or-later

/// spot.sol -- Spotter

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

import "../interfaces/IBookKeeper.sol";
import "../interfaces/IPriceFeed.sol";
import "../interfaces/IPriceOracle.sol";
import "../interfaces/ICagable.sol";

/// @title PriceOracle
/// @author Alpaca Fin Corporation
/** @notice A contract which is the price oracle of the BookKeeper to keep all collateral pools updated with the latest price of the collateral.
    The price oracle is important in reflecting the current state of the market price.
*/

contract PriceOracle is PausableUpgradeable, AccessControlUpgradeable, IPriceOracle, ICagable {
  bytes32 public constant OWNER_ROLE = DEFAULT_ADMIN_ROLE;
  bytes32 public constant GOV_ROLE = keccak256("GOV_ROLE");
  bytes32 public constant SHOW_STOPPER_ROLE = keccak256("SHOW_STOPPER_ROLE");

  // --- Data ---
  struct CollateralPool {
    IPriceFeed priceFeed; // Price Feed
    uint256 liquidationRatio; // Liquidation ratio or Collateral ratio [ray]
  }

  mapping(bytes32 => CollateralPool) public override collateralPools;

  IBookKeeper public bookKeeper; // CDP Engine
  uint256 public override stableCoinReferencePrice; // ref per dai [ray] :: value of stablecoin in the reference asset (e.g. $1 per Alpaca USD)

  uint256 public live;

  // --- Events ---
  event SetPrice(
    bytes32 poolId,
    bytes32 rawPrice, // Raw price from price feed [wad]
    uint256 priceWithSafetyMargin // Price with safety margin [ray]
  );

  // --- Init ---
  function initialize(address _bookKeeper) external initializer {
    PausableUpgradeable.__Pausable_init();
    AccessControlUpgradeable.__AccessControl_init();

    bookKeeper = IBookKeeper(_bookKeeper);
    stableCoinReferencePrice = ONE;
    live = 1;

    // Grant the contract deployer the owner role: it will be able
    // to grant and revoke any roles
    _setupRole(OWNER_ROLE, msg.sender);
  }

  // --- Math ---
  uint256 constant ONE = 10**27;

  function mul(uint256 x, uint256 y) internal pure returns (uint256 z) {
    require(y == 0 || (z = x * y) / y == x);
  }

  function rdiv(uint256 x, uint256 y) internal pure returns (uint256 z) {
    z = mul(x, ONE) / y;
  }

  // --- Administration ---
  event SetStableCoinReferencePrice(address indexed caller, uint256 data);
  event SetPriceFeed(address indexed caller, bytes32 poolId, address priceFeed);
  event SetLiquidationRatio(address indexed caller, bytes32 poolId, uint256 data);

  function setStableCoinReferencePrice(uint256 _data) external {
    require(hasRole(OWNER_ROLE, msg.sender), "!ownerRole");
    require(live == 1, "Spotter/not-live");
    stableCoinReferencePrice = _data;
    emit SetStableCoinReferencePrice(msg.sender, _data);
  }

  function setPriceFeed(bytes32 _poolId, address _priceFeed) external {
    require(hasRole(OWNER_ROLE, msg.sender), "!ownerRole");
    require(live == 1, "Spotter/not-live");
    collateralPools[_poolId].priceFeed = IPriceFeed(_priceFeed);
    emit SetPriceFeed(msg.sender, _poolId, _priceFeed);
  }

  function setLiquidationRatio(bytes32 _poolId, uint256 _data) external {
    require(hasRole(OWNER_ROLE, msg.sender), "!ownerRole");
    require(live == 1, "Spotter/not-live");
    collateralPools[_poolId].liquidationRatio = _data;
    emit SetLiquidationRatio(msg.sender, _poolId, _data);
  }

  // --- Update value ---
  /// @dev Update the latest price with safety margin of the collateral pool to the BookKeeper
  /// @param poolId Collateral pool id
  function setPrice(bytes32 poolId) external whenNotPaused {
    (bytes32 rawPrice, bool hasPrice) = collateralPools[poolId].priceFeed.peekPrice();
    uint256 priceWithSafetyMargin = hasPrice
      ? rdiv(rdiv(mul(uint256(rawPrice), 10**9), stableCoinReferencePrice), collateralPools[poolId].liquidationRatio)
      : 0;
    bookKeeper.setPriceWithSafetyMargin(poolId, priceWithSafetyMargin);
    emit SetPrice(poolId, rawPrice, priceWithSafetyMargin);
  }

  function cage() external override {
    require(
      hasRole(OWNER_ROLE, msg.sender) || hasRole(SHOW_STOPPER_ROLE, msg.sender),
      "!(ownerRole or showStopperRole)"
    );
    require(live == 1, "PriceOracle/not-live");
    live = 0;
    emit Cage();
  }

  function uncage() external override {
    require(
      hasRole(OWNER_ROLE, msg.sender) || hasRole(SHOW_STOPPER_ROLE, msg.sender),
      "!(ownerRole or showStopperRole)"
    );
    require(live == 0, "PriceOracle/not-caged");
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
