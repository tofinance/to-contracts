// SPDX-FileCopyrightText: 2023 Stake Together Labs <info@staketogether.app>
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/math/Math.sol';
import './StakeTogether.sol';

/// @custom:security-contact security@staketogether.app
contract Rewards is Ownable, Pausable, ReentrancyGuard {
  StakeTogether public stakeTogether;

  event EtherReceived(address indexed sender, uint amount);

  receive() external payable {
    emit EtherReceived(msg.sender, msg.value);
  }

  fallback() external payable {
    emit EtherReceived(msg.sender, msg.value);
  }

  event SetStakeTogether(address stakeTogether);

  function setStakeTogether(address _stakeTogether) external onlyOwner {
    require(address(stakeTogether) == address(0), 'STAKE_TOGETHER_ALREADY_SET');
    stakeTogether = StakeTogether(payable(_stakeTogether));
    emit SetStakeTogether(_stakeTogether);
  }

  /*****************
   ** TIME LOCK **
   *****************/

  event ProposeTimeLockAction(string action, uint256 value, address target, uint256 executionTime);
  event ExecuteTimeLockAction(string action);

  struct TimeLockedProposal {
    uint256 value;
    address target;
    uint256 executionTime;
  }

  uint256 public timeLockDuration = 1 days / 15;
  mapping(string => TimeLockedProposal) public timeLockedProposals;

  function proposeTimeLockAction(
    string calldata action,
    uint256 value,
    address target
  ) external onlyOwner {
    TimeLockedProposal storage proposal = timeLockedProposals[action];
    require(proposal.executionTime < block.timestamp, 'Previous proposal still pending.');

    proposal.value = value;
    proposal.target = target;
    proposal.executionTime = block.timestamp + timeLockDuration;

    emit ProposeTimeLockAction(action, value, target, proposal.executionTime);
  }

  function executeTimeLockAction(string calldata action) external onlyOwner {
    TimeLockedProposal storage proposal = timeLockedProposals[action];
    require(block.timestamp >= proposal.executionTime, 'Time lock not expired yet.');

    if (keccak256(bytes(action)) == keccak256(bytes('setTimeLockDuration'))) {
      timeLockDuration = proposal.value;
    } else if (keccak256(bytes(action)) == keccak256(bytes('setDisagreementLimit'))) {
      disagreementLimit = proposal.value;
    } else if (keccak256(bytes(action)) == keccak256(bytes('addOracle'))) {
      _addOracle(proposal.target);
    } else if (keccak256(bytes(action)) == keccak256(bytes('removeOracle'))) {
      _removeOracle(proposal.target);
    } else if (keccak256(bytes(action)) == keccak256(bytes('setPenalize'))) {
      penalizeLimit = proposal.value;
    }

    // Todo: missing some operations

    proposal.executionTime = 0;
    emit ExecuteTimeLockAction(action);
  }

  function isProposalReady(string memory proposalName) public view returns (bool) {
    TimeLockedProposal storage proposal = timeLockedProposals[proposalName];
    return block.timestamp >= proposal.executionTime;
  }

  /*****************
   ** ORACLES **
   *****************/

  modifier onlyOracle() {
    require(activeOracles[msg.sender] && oraclesBlacklist[msg.sender] < penalizeLimit, 'ONLY_ORACLES');
    _;
  }

  event AddOracle(address oracle);
  event RemoveOracle(address oracle);
  event SetBunkerMode(bool bunkerMode);
  event SetOracleQuorum(uint256 newQuorum);

  event OraclePenalized(
    address indexed oracle,
    uint256 penalties,
    bytes32 penalizedReportHash,
    BlockReport penalizedReport,
    bool removed
  );

  address[] private oracles;
  mapping(address => bool) private activeOracles;
  mapping(address => uint256) public oraclesBlacklist;
  uint256 public oracleQuorum = 1; // Todo: Mainnet = 3
  uint256 public penalizeLimit = 3;
  bool public bunkerMode = false;

  function getOracles() external view returns (address[] memory) {
    return oracles;
  }

  function getActiveOracleCount() internal view returns (uint256) {
    uint256 activeCount = 0;
    for (uint256 i = 0; i < oracles.length; i++) {
      if (activeOracles[oracles[i]]) {
        activeCount++;
      }
    }
    return activeCount;
  }

  function isOracle(address _oracle) public view returns (bool) {
    return activeOracles[_oracle] && oraclesBlacklist[_oracle] < penalizeLimit;
  }

  function setBunkerMode(bool _bunkerMode) external onlyOwner {
    bunkerMode = _bunkerMode;
    emit SetBunkerMode(_bunkerMode);
  }

  function _addOracle(address oracle) internal {
    require(!activeOracles[oracle], 'ORACLE_EXISTS');
    oracles.push(oracle);
    activeOracles[oracle] = true;
    emit AddOracle(oracle);
    _updateQuorum();
  }

  function _removeOracle(address oracle) internal {
    require(activeOracles[oracle], 'ORACLE_NOT_EXISTS');
    activeOracles[oracle] = false;
    emit RemoveOracle(oracle);
    _updateQuorum();
  }

  function _updateQuorum() internal onlyOwner {
    uint256 totalOracles = getActiveOracleCount();
    uint256 newQuorum = (totalOracles * 8) / 10;

    newQuorum = newQuorum < 3 ? 3 : newQuorum;
    newQuorum = newQuorum > totalOracles ? totalOracles : newQuorum;

    oracleQuorum = newQuorum;
    emit SetOracleQuorum(newQuorum);
  }

  function _penalizeOracle(address oracle, bytes32 faultyReportHash) internal {
    oraclesBlacklist[oracle]++;

    bool remove = oraclesBlacklist[oracle] >= penalizeLimit;
    if (remove) {
      _removeOracle(oracle);
    }

    emit OraclePenalized(
      oracle,
      oraclesBlacklist[oracle],
      faultyReportHash,
      blockReports[faultyReportHash],
      remove
    );
  }

  /*****************
   ** BLOCK REPORT **
   *****************/

  modifier onlyAfterBlockConsensus(bytes32 reportHash) {
    require(blockReports[reportHash].consensusExecuted, 'BLOCK_REPORT_CONSENSUS_NOT_EXECUTED');
    _;
  }

  event BlockConsensusApproved(uint256 indexed blockNumber, bytes32 reportHash);
  event BlockConsensusFail(uint256 indexed blockNumber, bytes32 reportHash);
  event BlockConsensusPending(uint256 indexed blockNumber, bytes32 reportHash);
  event BlockReportRequired(uint256 indexed blockNumber);

  struct BlockReport {
    uint256 blockNumber;
    uint256 beaconBalance;
    uint256 totalRewardsAmount;
    uint256 totalRewardsShares;
    uint256 stakeTogetherShares;
    uint256 operatorShares;
    uint256 poolShares;
    bytes[] exitedValidators;
    bool consensusExecuted;
    uint256 poolsToSubmit;
    uint256 poolSubmitted;
    uint256 poolSharesSubmitted;
  }

  mapping(bytes32 => BlockReport) public blockReports;
  mapping(uint256 => bytes32[]) public blockReportsByBlock;
  mapping(uint256 => bytes32) public blockConsensusHashByBlock;
  mapping(address => mapping(uint256 => bool)) public oracleBlockReport;

  uint256 public reportLastBlock = 0;
  uint256 public reportNextBlock = 1;
  uint256 public reportFrequency = 1;

  uint256 public disagreementLimit = 3;

  function submitBlockReport(
    uint256 blockNumber,
    uint256 beaconBalance,
    uint256 totalRewardsAmount,
    uint256 totalRewardsShares,
    uint256 stakeTogetherShares,
    uint256 operatorShares,
    uint256 poolShares,
    bytes[] calldata exitedValidators,
    uint256 poolsToSubmit
  ) external onlyOracle whenNotPaused {
    require(blockNumber != reportNextBlock, 'INVALID_REPORT_BLOCK_NUMBER');
    require(!oracleBlockReport[msg.sender][blockNumber], 'ORACLE_ALREADY_REPORTED');
    oracleBlockReport[msg.sender][blockNumber] = true;

    BlockReport memory blockReport = BlockReport(
      blockNumber,
      beaconBalance,
      totalRewardsAmount,
      totalRewardsShares,
      stakeTogetherShares,
      operatorShares,
      poolShares,
      exitedValidators,
      false,
      poolsToSubmit,
      0,
      0
    );

    _blockReportValidator(blockReport);

    bytes32 reportHash = keccak256(
      abi.encode(
        blockNumber,
        beaconBalance,
        totalRewardsAmount,
        totalRewardsShares,
        stakeTogetherShares,
        operatorShares,
        poolShares,
        exitedValidators,
        poolsToSubmit
      )
    );

    blockReportsByBlock[blockNumber].push(reportHash);

    blockReports[reportHash] = blockReport;
  }

  function executeBlockConsensus(uint256 blockNumber) external onlyOracle whenNotPaused {
    bytes32[] storage reports = blockReportsByBlock[blockNumber];
    uint256 maxVotes = 0;
    bytes32 consensusReportHash;

    for (uint256 i = 0; i < reports.length; i++) {
      bytes32 currentReportHash = reports[i];
      uint256 currentVotes = 0;

      for (uint256 j = 0; j < reports.length; j++) {
        if (currentReportHash == reports[j]) {
          currentVotes++;
        }
      }

      if (currentVotes > maxVotes) {
        consensusReportHash = currentReportHash;
        maxVotes = currentVotes;
        blockConsensusHashByBlock[blockNumber] = consensusReportHash;
      }
    }

    if (maxVotes >= oracleQuorum) {
      if (
        blockReports[consensusReportHash].poolShares ==
        blockReports[consensusReportHash].poolSharesSubmitted &&
        blockReports[consensusReportHash].poolShares ==
        blockReports[consensusReportHash].poolSharesSubmitted
      ) {
        BlockReport storage consensusReport = blockReports[consensusReportHash];

        consensusReport.consensusExecuted = true;

        // Todo: Integrate Stake Together

        reportNextBlock = consensusReport.blockNumber + 1;
        emit BlockConsensusApproved(blockNumber, consensusReportHash);
      } else {
        reportNextBlock = reportNextBlock + reportFrequency;
        emit BlockConsensusFail(blockNumber, consensusReportHash);
      }
    } else {
      reportNextBlock = reportNextBlock + reportFrequency;
      emit BlockConsensusFail(blockNumber, consensusReportHash);
    }
  }

  function isBlockReportReady(uint256 blockNumber) public view returns (bool) {
    return blockReportsByBlock[blockNumber].length >= oracleQuorum;
  }

  function _blockReportValidator(BlockReport memory _blockReport) internal {}

  /*****************
   ** POOL REPORT **
   *****************/

  event PoolConsensusApproved(uint256 indexed blockNumber, bytes32 reportHash);
  event PoolConsensusFail(uint256 indexed blockNumber, bytes32 reportHash);

  struct PoolReport {
    address pool;
    address sharesAmount;
    bytes32 reportHash;
    bool consensusExecuted;
  }

  mapping(bytes32 => PoolReport) public poolReports;
  mapping(bytes32 => PoolReport[]) public poolReportsByBlock;

  // function submitPoolReport(
  //   bytes32 reportHash,
  //   address[] calldata pools,
  //   uint256[] calldata sharesAmounts
  // ) external onlyAfterBlockConsensus(reportHash) onlyOracle whenNotPaused {
  //   require(reports[reportHash].blockNumber != 0, 'Report not submitted yet');
  //   require(pools.length == sharesAmounts.length, 'Mismatch in array lengths');

  //   bytes32 poolReportHash = keccak256(abi.encode(reportHash, pools, sharesAmounts));

  //   for (uint256 i = 0; i < sharesAmounts.length; i++) {
  //     reports[reportHash].poolSharesSubmitted += sharesAmounts[i];
  //   }

  //   poolReports[poolReportHash] = PoolReport(pools, sharesAmounts, reportHash);
  //   poolReportsByReportHash[reportHash].push(poolReportHash);
  // }

  // function executePoolConsensus(
  //   bytes32 reportHash,
  //   uint256 blockNumber,
  //   uint256 pageNumber
  // ) external onlyAfterBlockConsensus(reportHash) onlyOracle whenNotPaused {
  //   bytes32[] storage poolBlockReports = poolReportsByBlock[blockNumber];
  //   uint256 maxVotes = 0;
  //   bytes32 consensusReportHash;

  //   // Similar loop to find consensus report hash

  //   // If we got more votes than the oracleQuorum,
  //   // we consider it a valid report and update the state
  //   if (maxVotes >= oracleQuorum) {
  //     // Check if consensus was already executed for this pool report
  //     require(!consensusPoolReport.consensusExecuted, 'Consensus already executed for this pool report');

  //     consensusPoolReport.consensusExecuted = true;
  //     PoolReport memory consensusPoolReport = poolReports[consensusReportHash];

  //     uint256 pageSize = 100; // Define your preferred page size here
  //     uint256 startIndex = pageNumber * pageSize;
  //     require(startIndex < consensusPoolReport.pools.length, 'Page number out of range');

  //     uint256 endIndex = startIndex + pageSize > consensusPoolReport.pools.length
  //       ? consensusPoolReport.pools.length
  //       : startIndex + pageSize;

  //     uint256 totalShares = 0;
  //     for (uint256 i = startIndex; i < endIndex; i++) {
  //       totalShares += consensusPoolReport.sharesAmounts[i];
  //       // Process the pool shares here based on consensusPoolReport.sharesAmounts[i]
  //     }

  //     bytes32 generalReportHash = consensusReportHashByBlock[blockNumber];
  //     Report memory generalReport = reports[generalReportHash];

  //     require(totalShares <= generalReport.poolShares, 'Mismatch in poolShares total');

  //     if (endIndex == consensusPoolReport.pools.length) {
  //       // We've processed the last page
  //       emit PoolConsensusApproved(blockNumber, consensusReportHash);
  //     }
  //   } else {
  //     emit PoolConsensusFail(blockNumber, consensusReportHash);
  //   }
  // }
}
