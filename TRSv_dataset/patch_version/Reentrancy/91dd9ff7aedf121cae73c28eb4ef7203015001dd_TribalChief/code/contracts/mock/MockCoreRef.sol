// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.0;

import "../refs/CoreRef.sol";

contract MockCoreRef is CoreRef {
	constructor(address core) CoreRef(core) {}

	function testMinter() public view onlyMinter {}

	function testBurner() public view onlyBurner {}

	function testPCVController() public view onlyPCVController {}

	function testGovernor() public view onlyGovernor {}
}

