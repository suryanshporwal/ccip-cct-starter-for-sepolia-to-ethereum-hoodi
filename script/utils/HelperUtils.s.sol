// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";
import {HelperConfig} from "../HelperConfig.s.sol";

library HelperUtils {
    using stdJson for string;

    error UnsupportedChainId(uint256 chainId);

    struct BroadcastContract {
        address contractAddress;
        uint256 timestamp;
    }

    function getChainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == 43113) {
            return "avalancheFuji";
        } else if (chainId == 11155111) {
            return "ethereumSepolia";
        } else if (chainId == 560048) {
            return "ethereumHoodi";
        } else if (chainId == 421614) {
            return "arbitrumSepolia";
        } else if (chainId == 84532) {
            return "baseSepolia";
        } else {
            revert UnsupportedChainId(chainId);
        }
    }

    function getNetworkConfig(HelperConfig helperConfig, uint256 chainId)
        internal
        pure
        returns (HelperConfig.NetworkConfig memory)
    {
        if (chainId == 43113) {
            return helperConfig.getAvalancheFujiConfig();
        } else if (chainId == 11155111) {
            return helperConfig.getEthereumSepoliaConfig();
        } else if (chainId == 560048) {
            return helperConfig.getEthereumHoodiConfig();
        } else if (chainId == 421614) {
            return helperConfig.getArbitrumSepolia();
        } else if (chainId == 84532) {
            return helperConfig.getBaseSepoliaConfig();
        } else {
            revert UnsupportedChainId(chainId);
        }
    }

    function getAddressFromJson(Vm vm, string memory path, string memory key) internal view returns (address) {
        string memory json = vm.readFile(path);
        return json.readAddress(key);
    }

    function getDeployedTokenAddress(Vm vm, string memory root, string memory chainName, uint256 chainId)
        internal
        returns (address)
    {
        string memory outputPath = string.concat(root, "/script/output/deployedToken_", chainName, ".json");
        string memory outputKey = string.concat(".deployedToken_", chainName);
        BroadcastContract memory broadcastContract = _getLatestBroadcastContract(vm, root, "DeployToken.s.sol", chainId);

        return _resolveDeploymentAddress(vm, outputPath, outputKey, broadcastContract, chainId == block.chainid, "token");
    }

    function getDeployedTokenPoolAddress(Vm vm, string memory root, string memory chainName, uint256 chainId)
        internal
        returns (address)
    {
        string memory outputPath = string.concat(root, "/script/output/deployedTokenPool_", chainName, ".json");
        string memory outputKey = string.concat(".deployedTokenPool_", chainName);

        BroadcastContract memory burnMintPool =
            _getLatestBroadcastContract(vm, root, "DeployBurnMintTokenPool.s.sol", chainId);
        BroadcastContract memory lockReleasePool =
            _getLatestBroadcastContract(vm, root, "DeployLockReleaseTokenPool.s.sol", chainId);
        BroadcastContract memory broadcastContract = _selectLatestBroadcastContract(burnMintPool, lockReleasePool);

        return _resolveDeploymentAddress(
            vm, outputPath, outputKey, broadcastContract, chainId == block.chainid, "token pool"
        );
    }

    function getBoolFromJson(Vm vm, string memory path, string memory key) internal view returns (bool) {
        string memory json = vm.readFile(path);
        return json.readBool(key);
    }

    function getStringFromJson(Vm vm, string memory path, string memory key) internal view returns (string memory) {
        string memory json = vm.readFile(path);
        return json.readString(key);
    }

    function getUintFromJson(Vm vm, string memory path, string memory key) internal view returns (uint256) {
        string memory json = vm.readFile(path);
        return json.readUint(key);
    }

    function _resolveDeploymentAddress(
        Vm vm,
        string memory outputPath,
        string memory outputKey,
        BroadcastContract memory broadcastContract,
        bool requireDeployedCode,
        string memory contractLabel
    ) private returns (address) {
        address outputAddress = _readAddressIfPresent(vm, outputPath, outputKey);

        if (outputAddress != address(0)) {
            if (!requireDeployedCode || outputAddress.code.length > 0) {
                return outputAddress;
            }
        }

        if (broadcastContract.contractAddress != address(0)) {
            _writeAddressToJson(vm, outputPath, outputKey, broadcastContract.contractAddress);
            return broadcastContract.contractAddress;
        }

        require(outputAddress != address(0), string.concat("Unable to resolve deployed ", contractLabel, " address"));

        if (requireDeployedCode) {
            require(outputAddress.code.length > 0, string.concat("Configured ", contractLabel, " address is not a deployed contract"));
        }

        return outputAddress;
    }

    function _getLatestBroadcastContract(Vm vm, string memory root, string memory scriptName, uint256 chainId)
        private
        view
        returns (BroadcastContract memory)
    {
        string memory broadcastPath =
            string.concat(root, "/broadcast/", scriptName, "/", uintToStr(chainId), "/run-latest.json");

        if (!vm.exists(broadcastPath) || !vm.isFile(broadcastPath)) {
            return BroadcastContract({contractAddress: address(0), timestamp: 0});
        }

        string memory json = vm.readFile(broadcastPath);
        address contractAddress = json.readAddressOr(".receipts[0].contractAddress", address(0));
        if (contractAddress == address(0)) {
            contractAddress = json.readAddressOr(".transactions[0].contractAddress", address(0));
        }

        if (contractAddress == address(0)) {
            return BroadcastContract({contractAddress: address(0), timestamp: 0});
        }

        return BroadcastContract({contractAddress: contractAddress, timestamp: json.readUintOr(".timestamp", 0)});
    }

    function _selectLatestBroadcastContract(BroadcastContract memory left, BroadcastContract memory right)
        private
        pure
        returns (BroadcastContract memory)
    {
        if (left.contractAddress == address(0)) {
            return right;
        }

        if (right.contractAddress == address(0)) {
            return left;
        }

        return left.timestamp >= right.timestamp ? left : right;
    }

    function _readAddressIfPresent(Vm vm, string memory path, string memory key) private view returns (address) {
        if (!vm.exists(path) || !vm.isFile(path)) {
            return address(0);
        }

        string memory json = vm.readFile(path);
        return json.readAddressOr(key, address(0));
    }

    function _writeAddressToJson(Vm vm, string memory path, string memory key, address contractAddress) private {
        string memory jsonKey = "resolved_contract";
        string memory plainKey = key;

        if (bytes(key).length > 0 && bytes(key)[0] == ".") {
            plainKey = _sliceString(key, 1);
        }

        string memory finalJson = vm.serializeAddress(jsonKey, plainKey, contractAddress);
        vm.writeJson(finalJson, path);
    }

    function _sliceString(string memory input, uint256 start) private pure returns (string memory) {
        bytes memory source = bytes(input);
        bytes memory result = new bytes(source.length - start);

        for (uint256 i = start; i < source.length; i++) {
            result[i - start] = source[i];
        }

        return string(result);
    }

    function bytes32ToHexString(bytes32 _bytes) internal pure returns (string memory) {
        bytes memory hexString = new bytes(64);
        bytes memory hexAlphabet = "0123456789abcdef";
        for (uint256 i = 0; i < 32; i++) {
            hexString[i * 2] = hexAlphabet[uint8(_bytes[i] >> 4)];
            hexString[i * 2 + 1] = hexAlphabet[uint8(_bytes[i] & 0x0f)];
        }
        return string(hexString);
    }

    function uintToStr(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 length;
        while (j != 0) {
            length++;
            j /= 10;
        }
        bytes memory bstr = new bytes(length);
        uint256 k = length;
        j = _i;
        while (j != 0) {
            bstr[--k] = bytes1(uint8(48 + j % 10));
            j /= 10;
        }
        return string(bstr);
    }
}
