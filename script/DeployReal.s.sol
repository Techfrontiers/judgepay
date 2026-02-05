// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {JudgePayLite} from "../contracts/JudgePayLite.sol";

contract DeployReal is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address realUsdc = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // Base Sepolia USDC

        vm.startBroadcast(deployerPrivateKey);

        // Deploy JudgePayLite linked to REAL USDC
        JudgePayLite judgePay = new JudgePayLite(realUsdc);
        console.log("JudgePayLite (Real USDC) Deployed at:", address(judgePay));

        vm.stopBroadcast();
    }
}
