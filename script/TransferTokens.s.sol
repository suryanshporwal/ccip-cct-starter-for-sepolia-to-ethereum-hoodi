// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {HelperUtils} from "./utils/HelperUtils.s.sol"; // Utility functions for JSON parsing and chain info
import {HelperConfig} from "./HelperConfig.s.sol"; // Network configuration helper
import {IERC20} from
    "@chainlink/contracts-ccip/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/src/v0.8/ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";
import {TokenAdminRegistry} from "@chainlink/contracts-ccip/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";

contract TransferTokens is Script {
    enum Fee {
        Native,
        Link
    }

    function run() external {
        // Get the chain name based on the current chain ID
        string memory chainName = HelperUtils.getChainName(block.chainid);

        // Construct paths to the configuration and token JSON files
        string memory root = vm.projectRoot();
        string memory configPath = string.concat(root, "/script/config.json");

        // Resolve the latest valid token deployment for this chain and heal stale output files if needed.
        address tokenAddress = HelperUtils.getDeployedTokenAddress(vm, root, chainName, block.chainid);

        // Read the amount to transfer and feeType from config.json
        uint256 amount = HelperUtils.getUintFromJson(vm, configPath, ".tokenAmountToTransfer");
        string memory feeType = HelperUtils.getStringFromJson(vm, configPath, ".feeType");

        // Get the destination chain ID based on the current chain ID
        uint256 destinationChainId = HelperUtils.getUintFromJson(
            vm, configPath, string.concat(".remoteChains.", HelperUtils.uintToStr(block.chainid))
        );

        // Fetch the network configuration for the current chain
        HelperConfig helperConfig = new HelperConfig();
        (, address router,, address tokenAdminRegistry,, address link,,) = helperConfig.activeNetworkConfig();

        // Retrieve the remote network configuration
        HelperConfig.NetworkConfig memory remoteNetworkConfig =
            HelperUtils.getNetworkConfig(helperConfig, destinationChainId);
        uint64 destinationChainSelector = remoteNetworkConfig.chainSelector;

        require(tokenAddress != address(0), "Invalid token address");
        require(tokenAddress.code.length > 0, "Configured token address is not a deployed contract");
        require(amount > 0, "Invalid amount to transfer");
        require(destinationChainSelector != 0, "Chain selector not defined for the destination chain");
        _validateTokenSetup(tokenAdminRegistry, tokenAddress, amount, msg.sender);

        // Determine the fee token to use based on feeType
        address feeTokenAddress = _getFeeTokenAddress(feeType, link);

        vm.startBroadcast();

        // Connect to the CCIP router contract
        IRouterClient routerContract = IRouterClient(router);

        // Check if the destination chain is supported by the router
        require(routerContract.isChainSupported(destinationChainSelector), "Destination chain not supported");

        // Prepare the CCIP message
        Client.EVM2AnyMessage memory message = _buildMessage(msg.sender, feeTokenAddress, tokenAddress, amount);

        // Approve the router to transfer tokens on behalf of the sender
        IERC20(tokenAddress).approve(router, amount);

        // Estimate the fees required for the transfer
        uint256 fees = routerContract.getFee(destinationChainSelector, message);
        console.log("Estimated fees:", fees);
        _validateFeeBalance(feeTokenAddress, fees, msg.sender);

        // Send the CCIP message and handle fee payment
        bytes32 messageId;
        if (feeTokenAddress == address(0)) {
            // Pay fees with native token
            messageId = routerContract.ccipSend{value: fees}(destinationChainSelector, message);
        } else {
            // Approve the router to spend LINK tokens for fees
            IERC20(feeTokenAddress).approve(router, fees);
            messageId = routerContract.ccipSend(destinationChainSelector, message);
        }

        // Log the Message ID
        console.log("Message ID:");
        console.logBytes32(messageId);

        // Provide a URL to check the status of the message
        string memory messageUrl = string(
            abi.encodePacked(
                "Check status of the message at https://ccip.chain.link/msg/", HelperUtils.bytes32ToHexString(messageId)
            )
        );
        console.log(messageUrl);

        vm.stopBroadcast();
    }

    function _validateTokenSetup(address tokenAdminRegistry, address tokenAddress, uint256 amount, address sender)
        internal
        view
    {
        require(tokenAdminRegistry != address(0), "TokenAdminRegistry is not defined for this network");

        TokenAdminRegistry.TokenConfig memory tokenConfig =
            TokenAdminRegistry(tokenAdminRegistry).getTokenConfig(tokenAddress);
        require(tokenConfig.tokenPool != address(0), "Token pool is not set; run SetPool.s.sol first");

        uint256 tokenBalance = IERC20(tokenAddress).balanceOf(sender);
        console.log("Token balance:", tokenBalance);
        require(tokenBalance >= amount, "Insufficient token balance for transfer amount");
    }

    function _getFeeTokenAddress(string memory feeType, address link) internal pure returns (address) {
        if (keccak256(bytes(feeType)) == keccak256(bytes("native"))) {
            return address(0);
        }

        if (keccak256(bytes(feeType)) == keccak256(bytes("link"))) {
            return link;
        }

        revert("Invalid fee token");
    }

    function _buildMessage(address receiver, address feeTokenAddress, address tokenAddress, uint256 amount)
        internal
        pure
        returns (Client.EVM2AnyMessage memory message)
    {
        message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: abi.encode(),
            tokenAmounts: new Client.EVMTokenAmount[](1),
            feeToken: feeTokenAddress,
            extraArgs: abi.encodePacked(
                bytes4(keccak256("CCIP EVMExtraArgsV1")),
                abi.encode(uint256(0))
            )
        });

        message.tokenAmounts[0] = Client.EVMTokenAmount({token: tokenAddress, amount: amount});
    }

    function _validateFeeBalance(address feeTokenAddress, uint256 fees, address sender) internal view {
        if (feeTokenAddress == address(0)) {
            console.log("Native balance:", sender.balance);
            require(sender.balance >= fees, "Insufficient native balance to pay CCIP fees");
            return;
        }

        uint256 feeTokenBalance = IERC20(feeTokenAddress).balanceOf(sender);
        console.log("Fee token balance:", feeTokenBalance);
        require(feeTokenBalance >= fees, "Insufficient LINK balance to pay CCIP fees");
    }
}
