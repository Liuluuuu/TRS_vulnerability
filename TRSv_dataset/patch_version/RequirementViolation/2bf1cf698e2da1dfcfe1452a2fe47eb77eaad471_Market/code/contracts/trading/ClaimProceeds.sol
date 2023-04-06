pragma solidity 0.4.17;


import 'trading/IClaimProceeds.sol';
import 'Controlled.sol';
import 'libraries/ReentrancyGuard.sol';
import 'libraries/CashAutoConverter.sol';
import 'reporting/IMarket.sol';
import 'trading/ICash.sol';
import 'extensions/MarketFeeCalculator.sol';
import 'libraries/math/SafeMathUint256.sol';
import 'reporting/Reporting.sol';


// AUDIT: Ensure that a malicious market can't subversively cause share tokens to be paid out incorrectly.
/**
 * @title ClaimProceeds
 * @dev This allows users to claim their money from a market by exchanging their shares
 */
contract ClaimProceeds is CashAutoConverter, ReentrancyGuard, IClaimProceeds {
    using SafeMathUint256 for uint256;

    function claimProceeds(IMarket _market) convertToAndFromCash onlyInGoodTimes nonReentrant external returns(bool) {
        require(_market.getReportingState() == IMarket.ReportingState.FINALIZED);
        require(block.timestamp > _market.getFinalizationTime() + Reporting.claimProceedsWaitTime());

        IReportingToken _winningReportingToken = _market.getFinalWinningReportingToken();

        for (uint8 _outcome = 0; _outcome < _market.getNumberOfOutcomes(); ++_outcome) {
            IShareToken _shareToken = _market.getShareToken(_outcome);
            uint256 _numberOfShares = _shareToken.balanceOf(msg.sender);
            var (_proceeds, _shareHolderShare, _creatorShare, _reporterShare) = divideUpWinnings(_market, _winningReportingToken, _outcome, _numberOfShares);

            if (_proceeds > 0) {
                _market.getUniverse().decrementOpenInterest(_proceeds);
            }

            // always destroy shares as it gives a minor gas refund and is good for the network
            if (_numberOfShares > 0) {
                _shareToken.destroyShares(msg.sender, _numberOfShares);
            }
            ICash _denominationToken = _market.getDenominationToken();
            if (_shareHolderShare > 0) {
                require(_denominationToken.transferFrom(_market, msg.sender, _shareHolderShare));
            }
            if (_creatorShare > 0) {
                // For this payout we transfer Cash to this contract and then convert it into ETH before giving it ot the market owner
                // TODO: Write tests for this
                require(_denominationToken.transferFrom(_market, this, _creatorShare));
                _denominationToken.withdrawEtherTo(_market.getOwner(), _creatorShare);
            }
            if (_reporterShare > 0) {
                require(_denominationToken.transferFrom(_market, _market.getReportingWindow(), _reporterShare));
            }
        }

        return true;
    }

    function divideUpWinnings(IMarket _market, IReportingToken _winningReportingToken, uint8 _outcome, uint256 _numberOfShares) public returns (uint256 _proceeds, uint256 _shareHolderShare, uint256 _creatorShare, uint256 _reporterShare) {
        _proceeds = calculateProceeds(_winningReportingToken, _outcome, _numberOfShares);
        _creatorShare = calculateCreatorFee(_market, _proceeds);
        _reporterShare = calculateReportingFee(_market, _proceeds);
        _shareHolderShare = _proceeds.sub(_creatorShare).sub(_reporterShare);
        return (_proceeds, _shareHolderShare, _creatorShare, _reporterShare);
    }

    function calculateProceeds(IReportingToken _winningReportingToken, uint8 _outcome, uint256 _numberOfShares) public view returns (uint256) {
        uint256 _payoutNumerator = _winningReportingToken.getPayoutNumerator(_outcome);
        return _numberOfShares.mul(_payoutNumerator);
    }

    function calculateReportingFee(IMarket _market, uint256 _amount) public returns (uint256) {
        MarketFeeCalculator _marketFeeCalculator = MarketFeeCalculator(controller.lookup("MarketFeeCalculator"));
        IReportingWindow _reportingWindow = _market.getReportingWindow();
        uint256 _reportingFeeAttoethPerEth = _marketFeeCalculator.getReportingFeeInAttoethPerEth(_reportingWindow);
        return _amount.mul(_reportingFeeAttoethPerEth).div(1 ether);
    }

    function calculateCreatorFee(IMarket _market, uint256 _amount) public view returns (uint256) {
        uint256 _creatorFeeAttoEthPerEth = _market.getMarketCreatorSettlementFeeInAttoethPerEth();
        return _amount.mul(_creatorFeeAttoEthPerEth).div(1 ether);
    }
}
