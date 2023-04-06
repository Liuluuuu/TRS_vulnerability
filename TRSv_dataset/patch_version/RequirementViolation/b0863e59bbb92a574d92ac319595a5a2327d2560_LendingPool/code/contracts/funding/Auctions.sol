/*

    Copyright 2019 The Hydro Protocol Foundation

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.

*/

pragma solidity ^0.5.8;
pragma experimental ABIEncoderV2;

import "./LendingPool.sol";
import "../lib/Store.sol";
import "../lib/SafeMath.sol";
import "../lib/Types.sol";
import "../lib/Events.sol";
import "../lib/Decimal.sol";
import "../lib/Transfer.sol";

library Auctions {
    using SafeMath for uint256;
    using Auction for Types.Auction;

    function fillAuctionWithAmount(
        Store.State storage state,
        uint32 auctionID,
        uint256 repayAmount
    )
        internal
    {
        Types.Auction storage auction = state.auction.auctions[auctionID];

        uint256 leftDebtAmount = LendingPool.getBorrowOf(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        uint256 leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];

        // transfer valid repay amount from msg.sender to auction.borrower
        uint256 validRepayAmount = repayAmount < leftDebtAmount ? repayAmount : leftDebtAmount;

        state.balances[msg.sender][auction.debtAsset] = SafeMath.sub(
            state.balances[msg.sender][auction.debtAsset],
            validRepayAmount
        );

        state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset] = SafeMath.add(
            state.accounts[auction.borrower][auction.marketID].balances[auction.debtAsset],
            validRepayAmount
        );

        LendingPool.repay(
            state,
            auction.borrower,
            auction.marketID,
            auction.debtAsset,
            repayAmount
        );

        uint256 ratio = auction.ratio(state);

        uint256 amountToProcess = leftCollateralAmount.mul(validRepayAmount).div(leftDebtAmount);
        uint256 amountForBidder = Decimal.mul(amountToProcess, ratio);
        uint256 amountForInitiator = Decimal.mul(amountToProcess.sub(amountForBidder), state.auction.initiatorRewardRatio);
        uint256 amountForBorrower = amountToProcess.sub(amountForBidder).sub(amountForInitiator);

        // update collateralAmount
        state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset] = SafeMath.sub(
            state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset],
            amountToProcess
        );

        // bidder receive collateral
        state.balances[msg.sender][auction.collateralAsset] = SafeMath.add(
            state.balances[msg.sender][auction.collateralAsset],
            amountForBidder
        );

        // initiator receive collateral
        state.balances[auction.initiator][auction.collateralAsset] = SafeMath.add(
            state.balances[auction.initiator][auction.collateralAsset],
            amountForInitiator
        );

        // auction.borrower receive collateral
        state.balances[auction.borrower][auction.collateralAsset] = SafeMath.add(
            state.balances[auction.borrower][auction.collateralAsset],
            amountForBorrower
        );

        Events.logFillAuction(auctionID, validRepayAmount);

        // reset account state if all debts are paid
        if (leftDebtAmount <= repayAmount) {
            endAuction(state, auctionID);
        }
    }

    function closeAbortiveAuction(
        Store.State storage state,
        uint32 auctionID
    )
        internal
    {
        Types.Auction storage auction = state.auction.auctions[auctionID];

        require(auction.status == Types.AuctionStatus.InProgress, "AUCTION_NOT_IN_PROGRESS");
        require(auction.ratio(state) == Decimal.one(), "AUCTION_NOT_END");

        uint256 compensationAmount = LendingPool.compensate(
            state,
            auction.borrower,
            auction.marketID,
            auction.debtAsset,
            auction.collateralAsset
        );

        // repay
        LendingPool.repay(
            state,
            auction.borrower,
            auction.marketID,
            auction.debtAsset,
            compensationAmount
        );

        // Check the debt again.
        uint256 badDebtAmount = LendingPool.getBorrowOf(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        // All lost are shared by all lenders, if still some debt there.
        if (badDebtAmount > 0){
            LendingPool.lose(
                state,
                auction.borrower,
                auction.marketID,
                auction.debtAsset,
                badDebtAmount
            );
        }

        endAuction(state, auctionID);
    }

    function endAuction(
        Store.State storage state,
        uint32 auctionID
    )
        internal
    {
        Types.Auction storage auction = state.auction.auctions[auctionID];
        auction.status = Types.AuctionStatus.Finished;

        Types.CollateralAccount storage account = state.accounts[auction.borrower][auction.marketID];
        account.status = Types.CollateralAccountStatus.Normal;

        for (uint i = 0; i < state.auction.currentAuctions.length; i++){
            if (state.auction.currentAuctions[i] == auctionID){
                state.auction.currentAuctions[i] = state.auction.currentAuctions[state.auction.currentAuctions.length-1];
                state.auction.currentAuctions.length--;
            }
        }

        Events.logAuctionFinished(auctionID);
    }

    /**
     * Create an auction and save it in global state
     *
     */
    function create(
        Store.State storage state,
        uint16 marketID,
        address borrower,
        address initiator,
        address debtAsset,
        address collateralAsset
    )
        internal
        returns (uint32)
    {
        uint32 id = state.auction.auctionsCount++;

        Types.Auction memory auction = Types.Auction({
            id: id,
            status: Types.AuctionStatus.InProgress,
            startBlockNumber: uint32(block.number),
            marketID: marketID,
            borrower: borrower,
            initiator: initiator,
            debtAsset: debtAsset,
            collateralAsset: collateralAsset
        });

        state.auction.auctions[id] = auction;
        state.auction.currentAuctions.push(id);

        Events.logAuctionCreate(id);

        return id;
    }

    function getAuctionDetails(
        Store.State storage state,
        uint32 auctionID
    )
        internal
        view
        returns (Types.AuctionDetails memory details)
    {
        Types.Auction memory auction = state.auction.auctions[auctionID];

        details.debtAsset = auction.debtAsset;
        details.collateralAsset = auction.collateralAsset;

        details.leftDebtAmount = LendingPool.getBorrowOf(
            state,
            auction.debtAsset,
            auction.borrower,
            auction.marketID
        );

        details.leftCollateralAmount = state.accounts[auction.borrower][auction.marketID].balances[auction.collateralAsset];
        details.ratio = auction.ratio(state);
    }
}