// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.12;

import './interface/ICoFiXKTable.sol';

// KTable contract to store k values, used by CoFiXController contract
// The K0 values are set for only once, and not changeable after set
// Anyone could validate by https://github.com/Computable-Finance/CoFiX/blob/master/scripts/setKTable.js
contract CoFiXKTable is ICoFiXKTable {

    address public governance;

    int128[20][91] public k0Table; // sigmaIdx (0~29), tIdx (0~90)

    modifier onlyGovernance() {
        require(msg.sender == governance, "CKTable: !governance");
        _;
    }

    constructor() public {
        governance = msg.sender;
    }

    function setK0(uint256 tIdx, uint256 sigmaIdx, int128 k0) external override onlyGovernance {
        require(k0Table[tIdx][sigmaIdx] == 0, "CKTable: already set"); // only once, and not changeable
        k0Table[tIdx][sigmaIdx] = k0;
    }

    function setK0InBatch(uint256[] memory tIdxs, uint256[] memory sigmaIdxs, int128[] memory k0s) external override onlyGovernance {
        uint256 loopCnt = tIdxs.length;
        require(loopCnt == sigmaIdxs.length, "CKTable: tIdxs sigmaIdx not match");
        require(loopCnt == k0s.length, "CKTable: tIdxs k0s not match");
        for (uint256 i = 0; i < loopCnt; i++) {
            require(k0Table[tIdxs[i]][sigmaIdxs[i]] == 0, "CKTable: already set"); // only once, and not changeable
            k0Table[tIdxs[i]][sigmaIdxs[i]] = k0s[i];
        }
    }

    function getK0(uint256 tIdx, uint256 sigmaIdx) external view override returns (int128) {
        require(tIdx < 91, "CKTable: tIdx must < 91");
        require(sigmaIdx < 20, "CKTable: sigmaIdx must < 20");
        return k0Table[tIdx][sigmaIdx];
    }
}