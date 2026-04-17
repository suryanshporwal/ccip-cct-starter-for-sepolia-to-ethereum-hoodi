// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperUtils} from "./utils/HelperUtils.s.sol"; // Utility functions for JSON parsing and chain info
import {HelperConfig} from "./HelperConfig.s.sol"; // Network configuration helper
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";

// Script contract to set the token pool in the TokenAdminRegistry
contract SetPool is Script {
    function run() external {
        // Get the chain name based on the current chain ID
        string memory chainName = HelperUtils.getChainName(block.chainid);

        string memory root = vm.projectRoot();

        // Resolve the latest valid token and pool deployments for this chain and heal stale output files if needed.
        address tokenAddress = HelperUtils.getDeployedTokenAddress(vm, root, chainName, block.chainid);
        address poolAddress = HelperUtils.getDeployedTokenPoolAddress(vm, root, chainName, block.chainid);

        // Fetch the network configuration to get the TokenAdminRegistry address
        HelperConfig helperConfig = new HelperConfig();
        (,,, address tokenAdminRegistry,,,,) = helperConfig.activeNetworkConfig();

        require(tokenAddress != address(0), "Invalid token address");
        require(poolAddress != address(0), "Invalid pool address");
        require(poolAddress.code.length > 0, "Configured pool address is not a deployed contract");
        require(tokenAdminRegistry != address(0), "TokenAdminRegistry is not defined for this network");

        vm.startBroadcast();

        // Instantiate the TokenAdminRegistry contract
        TokenAdminRegistry tokenAdminRegistryContract = TokenAdminRegistry(tokenAdminRegistry);

        // Fetch the token configuration to get the administrator's address
        TokenAdminRegistry.TokenConfig memory config = tokenAdminRegistryContract.getTokenConfig(tokenAddress);
        address signer = msg.sender;

        console.log("Setting pool for token:", tokenAddress);
        console.log("New pool address:", poolAddress);
        console.log("Current administrator:", config.administrator);
        console.log("Pending administrator:", config.pendingAdministrator);
        console.log("Broadcast signer:", signer);

        if (config.tokenPool == poolAddress) {
            console.log("Pool is already set for token:", tokenAddress);
            vm.stopBroadcast();
            return;
        }

        if (config.administrator != signer) {
            if (config.pendingAdministrator == signer) {
                revert("Signer is pending administrator; run AcceptAdminRole.s.sol first");
            }

            revert("Signer is not the current token administrator");
        }

        // Use the administrator's address to set the pool for the token
        tokenAdminRegistryContract.setPool(tokenAddress, poolAddress);

        console.log("Pool set for token", tokenAddress, "to", poolAddress);

        vm.stopBroadcast();
    }
}
