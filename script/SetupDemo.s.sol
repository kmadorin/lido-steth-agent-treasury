// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title SetupDemo — deploy AgentTreasury on Anvil fork (funding done via cast)
/// @notice Run: forge script script/SetupDemo.s.sol --rpc-url http://localhost:8545 --broadcast
contract SetupDemo is Script {
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant CHAINLINK_WSTETH_STETH = 0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061;

    address constant OWNER = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    address constant AGENT = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant SERVER = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external {
        uint256 ownerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        vm.startBroadcast(ownerKey);

        AgentTreasury treasury = new AgentTreasury(WSTETH, CHAINLINK_WSTETH_STETH, OWNER, AGENT);
        console.log("Treasury:", address(treasury));

        vm.stopBroadcast();
    }
}
