// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interface/IERC20.sol";
import "./interface/USDTERC20.sol";

/**
 * @title MPForwarderV1
 * @notice Payment forwarder with factory-only initialization
 * @dev Security fixes:
 *   1. Added `factory` immutable - only factory can call init
 *   2. Factory address embedded in bytecode for collision resistance
 */
contract MPForwarderV1 {
    address public immutable factory;
    address public destination;

    modifier onlyFactory() {
        require(msg.sender == factory, "only factory");
        _;
    }

    /**
     * @notice Constructor sets factory address (immutable)
     * @param _factory The factory contract address
     * @param _destination The destination for flushes (set to non-zero for implementation)
     */
    constructor(address _factory, address _destination) {
        require(_factory != address(0), "invalid factory");
        factory = _factory;
        destination = _destination;
    }

    /**
     * @notice Initialize clone with destination
     * @dev Can only be called by factory, can only be called once
     */
    function init(address _destination) external onlyFactory {
        require(destination == address(0), "already initialized");
        require(_destination != address(0), "invalid destination");
        destination = _destination;
    }

    /**
     * @notice Initialize and immediately flush funds to destination
     * @dev Can only be called by factory
     */
    function initAndFlush(
        address _destination,
        address _tokenAddress,
        bool _isUSDT
    ) external onlyFactory {
        require(destination == address(0), "already initialized");
        require(_destination != address(0), "invalid destination");
        destination = _destination;

        // Flush based on token type
        if (_tokenAddress == address(0)) {
            _flushETH();
        } else if (_isUSDT) {
            _flushUSDT(_tokenAddress);
        } else {
            _flushERC20(_tokenAddress);
        }
    }

    receive() external payable {}

    // ============ Public Flush Functions ============
    // Anyone can flush - funds always go to destination (safe)

    function flushETH() external {
        _flushETH();
    }

    function flushERC20(address tokenContractAddress) external {
        _flushERC20(tokenContractAddress);
    }

    function flushUSDT(address tokenContractAddress) external {
        _flushUSDT(tokenContractAddress);
    }

    // ============ Internal Functions ============

    function _flushETH() internal {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool success, ) = destination.call{value: balance}("");
            require(success, "flush ETH failed");
        }
    }

    function _flushERC20(address tokenContractAddress) internal {
        IERC20 tokenContract = IERC20(tokenContractAddress);
        uint256 balance = tokenContract.balanceOf(address(this));
        if (balance > 0) {
            tokenContract.transfer(destination, balance);
        }
    }

    function _flushUSDT(address tokenContractAddress) internal {
        USDTERC20 tokenContract = USDTERC20(tokenContractAddress);
        uint256 balance = tokenContract.balanceOf(address(this));
        if (balance > 0) {
            tokenContract.transfer(destination, balance);
        }
    }
}
