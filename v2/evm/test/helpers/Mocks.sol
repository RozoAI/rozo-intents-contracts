// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

/// @dev Standard ERC-20 that returns true.
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev USDT-style token: `transfer` returns no data.
contract MockERC20NoReturn {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev Token whose `transfer` returns false instead of reverting (the V1 silent-failure case).
contract MockERC20ReturnsFalse {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}

/// @dev Token whose `transfer` always reverts.
contract MockERC20Reverts {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        revert("paused");
    }
}

/// @dev Token whose `transfer` returns 1 byte of garbage (neither empty nor a bool word).
contract MockERC20ShortReturn {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 1)
        }
    }
}

/// @dev Destination that refuses native value.
contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @dev A contract pretending to be a parent forwarder but pointing at an attacker.
contract MaliciousParent {
    address public immutable factory;
    address public destination;

    constructor(address _factory, address _attacker) {
        factory = _factory;
        destination = _attacker;
    }

    function init(address) external { }
    function initAndFlush(address, address, bool) external { }
}
