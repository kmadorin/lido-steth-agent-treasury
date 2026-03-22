// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {AgentTreasury} from "../src/AgentTreasury.sol";

contract DeployAll is Script {
    // Base mainnet
    address constant WSTETH = 0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452;
    address constant CHAINLINK_WSTETH_STETH = 0xB88BAc61a4Ca37C43a3725912B1f472c9A5bc061;

    function run() external {
        address owner = vm.envAddress("OWNER_ADDRESS");
        address agent = vm.envAddress("AGENT_ADDRESS");

        vm.startBroadcast();

        AgentTreasury treasury = new AgentTreasury(WSTETH, CHAINLINK_WSTETH_STETH, owner, agent);
        console.log("AgentTreasury deployed:", address(treasury));

        vm.stopBroadcast();
    }
}
