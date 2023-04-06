pragma solidity ^0.4.13;

import 'libraries/Delegator.sol';
import 'IController.sol';
import 'reporting/IUniverse.sol';


contract UniverseFactory {
    function createUniverse(IController _controller, IUniverse _parentUniverse, bytes32 _parentPayoutDistributionHash) returns (IUniverse) {
        Delegator _delegator = new Delegator(_controller, "Universe");
        IUniverse _universe = IUniverse(_delegator);
        _universe.initialize(_parentUniverse, _parentPayoutDistributionHash);
        return _universe;
    }
}
