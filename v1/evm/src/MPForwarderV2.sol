// SPDX-License-Identifier: BSD-2-Clause
pragma solidity ^0.8.0;
import "./interface/IERC20.sol";
import "./interface/USDTERC20.sol";

contract MPForwarderV2 {
  address public destination;
  address public relayer;

  enum InitType {
    NONE,
    TRANSFER_ETH,
    TRANSFER_ERC20,
    TRANSFER_USDT,
    FLUSH_ETH,
    FLUSH_ERC20,
    FLUSH_USDT
  }

  modifier onlyRelayer() {
    require(msg.sender == relayer, "only relayer");
    _;
  }

  constructor(address _destination, address _relayer) {
    destination = _destination;
    relayer = _relayer;
  }

  // Init function for cloned forwarders - only sets addresses
  function init(
    address _destination,
    address _relayer
  ) public {
    require(destination == address(0x0), "already initialized");
    require(_destination != address(0x0), "invalid destination");
    require(_relayer != address(0x0), "invalid relayer");
    destination = _destination;
    relayer = _relayer;
  }

  // Init and flush function for cloned forwarders with immediate action
  function initAndFlush(
    address _destination,
    address _relayer,
    InitType _initType,
    address _tokenAddress,
    address _to,
    uint256 _amount
  ) public {
    require(destination == address(0x0), "dest inited");
    require(relayer == address(0x0), "relayer inited");
    require(_destination != address(0x0), "invalid destination");
    require(_relayer != address(0x0), "invalid relayer");
    destination = _destination;
    relayer = _relayer;

    if (_initType == InitType.TRANSFER_ETH) {
      _transferETH(_to, _amount);
      _flushETH(); // flush remaining
    } else if (_initType == InitType.TRANSFER_ERC20) {
      _transferERC20(_tokenAddress, _to, _amount);
      _flushERC20(_tokenAddress); // flush remaining
    } else if (_initType == InitType.TRANSFER_USDT) {
      _transferUSDT(_tokenAddress, _to, _amount);
      _flushUSDT(_tokenAddress); // flush remaining
    } else if (_initType == InitType.FLUSH_ETH) {
      _flushETH();
    } else if (_initType == InitType.FLUSH_ERC20) {
      _flushERC20(_tokenAddress);
    } else if (_initType == InitType.FLUSH_USDT) {
      _flushUSDT(_tokenAddress);
    }
  }

  receive() external payable {}

  // Transfer functions (relayer only) - transfers amount, then flushes remaining
  function transferETH(address to, uint256 amount) public onlyRelayer {
    _transferETH(to, amount);
    _flushETH();
  }

  function transferERC20(
    address tokenContractAddress,
    address to,
    uint256 amount
  ) public onlyRelayer {
    _transferERC20(tokenContractAddress, to, amount);
    _flushERC20(tokenContractAddress);
  }

  function transferUSDT(
    address tokenContractAddress,
    address to,
    uint256 amount
  ) public onlyRelayer {
    _transferUSDT(tokenContractAddress, to, amount);
    _flushUSDT(tokenContractAddress);
  }

  function _transferETH(address to, uint256 amount) internal {
    require(amount > 0, "amount must be > 0");
    require(address(this).balance >= amount, "insufficient ETH balance");
    (bool success, ) = to.call{value: amount}("");
    require(success, "ETH transfer failed");
  }

  function _transferERC20(
    address tokenContractAddress,
    address to,
    uint256 amount
  ) internal {
    require(amount > 0, "amount must be > 0");
    IERC20 tokenContract = IERC20(tokenContractAddress);
    uint256 balance = tokenContract.balanceOf(address(this));
    require(balance >= amount, "insufficient ERC20 balance");
    tokenContract.transfer(to, amount);
  }

  function _transferUSDT(
    address tokenContractAddress,
    address to,
    uint256 amount
  ) internal {
    require(amount > 0, "amount must be > 0");
    USDTERC20 tokenContract = USDTERC20(tokenContractAddress);
    uint256 balance = tokenContract.balanceOf(address(this));
    require(balance >= amount, "insufficient USDT balance");
    tokenContract.transfer(to, amount);
  }

  // Flush functions (anyone can call)
  function flushETH() public {
    _flushETH();
  }

  function flushERC20(address tokenContractAddress) public {
    _flushERC20(tokenContractAddress);
  }

  function flushUSDT(address tokenContractAddress) public {
    _flushUSDT(tokenContractAddress);
  }

  function _flushETH() internal {
    uint256 balance = address(this).balance;
    if (balance > 0) {
      (bool success, ) = destination.call{value: balance}("");
      require(success, "x");
    }
  }

  function _flushERC20(address tokenContractAddress) internal {
    IERC20 tokenContract = IERC20(tokenContractAddress);
    uint256 forwarderBalance = tokenContract.balanceOf(address(this));
    if (forwarderBalance > 0) {
      tokenContract.transfer(destination, forwarderBalance);
    }
  }

  function _flushUSDT(address tokenContractAddress) internal {
    USDTERC20 tokenContract = USDTERC20(tokenContractAddress);
    uint256 forwarderBalance = tokenContract.balanceOf(address(this));
    if (forwarderBalance > 0) {
      tokenContract.transfer(destination, forwarderBalance);
    }
  }
}
