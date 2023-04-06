// SPDX-License-Identifier: AGPL-3.0-or-later

/// deposit.sol -- Basic token adapters

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
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

import "../../interfaces/IBookKeeper.sol";
import "../../interfaces/IToken.sol";
import "../../interfaces/IGenericTokenAdapter.sol";
import "../../interfaces/ICagable.sol";
import "../../utils/SafeToken.sol";

/*
    Here we provide *adapters* to connect the BookKeeper to arbitrary external
    token implementations, creating a bounded context for the BookKeeper. The
    adapters here are provided as working examples:

      - `TokenAdapter`: For well behaved ERC20 tokens, with simple transfer
                   semantics.

      - `StablecoinAdapter`: For connecting internal Alpaca Stablecoin balances to an external
                   `AlpacaStablecoin` implementation.

    In practice, adapter implementations will be varied and specific to
    individual collateral types, accounting for different transfer
    semantics and token standards.

    Adapters need to implement two basic methods:

      - `deposit`: enter token into the system
      - `withdraw`: remove token from the system

*/

contract TokenAdapter is
  PausableUpgradeable,
  AccessControlUpgradeable,
  ReentrancyGuardUpgradeable,
  IGenericTokenAdapter,
  ICagable
{
  using SafeToken for address;

  // --- Auth ---
  bytes32 public constant OWNER_ROLE = DEFAULT_ADMIN_ROLE;
  bytes32 public constant SHOW_STOPPER_ROLE = keccak256("SHOW_STOPPER_ROLE");

  modifier onlyOwner() {
    require(hasRole(OWNER_ROLE, msg.sender), "!ownerRole");
    _;
  }

  IBookKeeper public bookKeeper; // CDP Engine
  bytes32 public override collateralPoolId; // Collateral Type
  address public override collateralToken;
  uint256 public override decimals;
  uint256 public live; // Active Flag

  function initialize(
    address _bookKeeper,
    bytes32 collateralPoolId_,
    address collateralToken_
  ) external initializer {
    PausableUpgradeable.__Pausable_init();
    AccessControlUpgradeable.__AccessControl_init();
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

    _setupRole(OWNER_ROLE, msg.sender);

    live = 1;
    bookKeeper = IBookKeeper(_bookKeeper);
    collateralPoolId = collateralPoolId_;
    collateralToken = collateralToken_;
    decimals = IToken(collateralToken).decimals();

    // Grant the contract deployer the owner role: it will be able
    // to grant and revoke any roles
    _setupRole(OWNER_ROLE, msg.sender);
  }

  function cage() external override {
    require(
      hasRole(OWNER_ROLE, msg.sender) || hasRole(SHOW_STOPPER_ROLE, msg.sender),
      "!(ownerRole or showStopperRole)"
    );
    require(live == 1, "TokenAdapter/not-live");
    live = 0;
    emit Cage();
  }

  function uncage() external override {
    require(
      hasRole(OWNER_ROLE, msg.sender) || hasRole(SHOW_STOPPER_ROLE, msg.sender),
      "!(ownerRole or showStopperRole)"
    );
    require(live == 0, "TokenAdapter/not-caged");
    live = 1;
    emit Uncage();
  }

  /// @dev Deposit token into the system from the caller to be used as collateral
  /// @param usr The source address which is holding the collateral token
  /// @param wad The amount of collateral to be deposited [wad]
  function deposit(
    address usr,
    uint256 wad,
    bytes calldata /* data */
  ) external payable override nonReentrant {
    require(live == 1, "TokenAdapter/not-live");
    require(int256(wad) >= 0, "TokenAdapter/overflow");
    bookKeeper.addCollateral(collateralPoolId, usr, int256(wad));

    // Move the actual token
    address(collateralToken).safeTransferFrom(msg.sender, address(this), wad);
  }

  /// @dev Withdraw token from the system to the caller
  /// @param usr The destination address to receive collateral token
  /// @param wad The amount of collateral to be withdrawn [wad]
  function withdraw(
    address usr,
    uint256 wad,
    bytes calldata /* data */
  ) external override nonReentrant {
    require(wad <= 2**255, "TokenAdapter/overflow");
    bookKeeper.addCollateral(collateralPoolId, msg.sender, -int256(wad));

    // Move the actual token
    address(collateralToken).safeTransfer(usr, wad);
  }

  function onAdjustPosition(
    address src,
    address dst,
    int256 collateralValue,
    int256 debtShare,
    bytes calldata data
  ) external override nonReentrant {}

  function onMoveCollateral(
    address src,
    address dst,
    uint256 wad,
    bytes calldata data
  ) external override nonReentrant {}
}
