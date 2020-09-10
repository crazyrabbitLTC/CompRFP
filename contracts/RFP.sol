// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import './ICompound.sol';
import "./CrowdProposalFactory";

interface ICAPFactory {
    function createCrowdProposal(address[] memory targets, uint[] memory values, string[] memory signatures, bytes[] memory calldatas, string memory description) external;
}

contract RequestForProposal {
    /// @notice `COMP` token contract address
    address public immutable comp;
    /// @notice Crowd Proposal factory contract address
    address public immutable CAPFactory;

    // Should we let governor alpha reclaim lost funds? 

    /// @notice Minimum duration for a RFP
    uint256 public minDuration;

    /// @notice Status of a Proposal
    enum RFPStatus {
        open,
        closed,
        awarded,
        expired,
        cancelled,
        proposed
    }

    /// @notice Status of a Submission
    enum RFPSubmissionStatus {
        submitted,
        selected,
        proposed,
        rejected,
    }

    /// @notice The number of RFP's in the system
    /// @notice This should be replaces with OpenZeppelin Counters
    uint256 public RFPCount;

    /// @notice Describes the components of a Request for Proposal
    struct RFP {
        address requestor;
        uint256 id;
        uint256 submissionDate;
        uint256 expiry;
        string requestDescription;
        uint256 bounty;
        RFPStatus status;
        bool awarded;
    }

    /// @notice Mapping of Request for proposals by integer
    mapping(uint => RFP) requestsForProposals;

    /// @notice Descibes the contents of a RFP submission
    struct Submission {
        uint256 RFPId;
        address creator;
        string submissionDescription;
        RFPSubmissionStatus status;
        address[] targets,
        uint256[] values,
        string[] signatures,
        bytes[] calldatas,
        string description
    }

    /// @notice Library of all RFP submissions mapping RFPId to submission ids
    mapping(uint => mapping(uint => Submission)) submissions;

    /// @notice A count of all submissions
    uint256 public submissionCount;

    /// @notice An event emitted on the creation of a RFP
    event RFPCreated(address indexed creator, uint256 bounty, uint256 expiry, string description );

    /// @notice An event emitted on the change of state of a RFP
    event RFPStatusChanged(uint256 RFPId, RFPStatus Status);

    /// @notice An event emitted on the submission of a Proposal to a RFP
    event SubmissionCreated(address indexed creator, uint256 RFPId); 

    /// @notice An event emitted on the change of status of a Proposal
    event SubmissionChanged(uint RFP, uint SubmissionId, RFPSubmissionStatus status);

    constructor(address capFactory_, address comp_ uint256 minDuration_) public {
        CAPFactory = capFactory_;
        comp = comp_;
        minDuration = minDuration_;
    }

    /**
    * @notice Create a new Request for Proposal
    * @notice Call 'Comp.approve(RFP_Contract_Address, compStakeAmount') before calling this method
    * @param requestDescription The offChain source of human readable description about the RFP
    * @param expiry The Expiration date at which the RFP is no longer valid
    * @param bounty The bounty, in COMP that will be paid out on accepted request
    */
    function createRFP(string memory requestDescription, uint256 expiry, uint256 bounty) external {
        //Get the bounty and lock it up
        require(IComp(comp).transferFrom(msg.sender, address(this), bounty), "Failed to receive bounty");
        //Make sure expiration date is after now
        require(expiry > block.number+minDuration, "Expiration date must be minDuration in the future");
        

        RFP memory rfp;
        uint256 currentCount = RFPCount + 1;
        RFPCount++;

        rfp.requestor = msg.sender;
        rfp.id = currentCount;
        rfp.submissionDate = block.number;
        rfp.expiry = expiry;
        rfp.requestDescription = requestDescription;
        rfp.bounty = bounty;
        rfp.RFPStatus = RFPStatus.open;
        rfp.awarded = false;

        requestsForProposals[currentCount] = rfp;

        emit RFPCreated(msg.sender, bounty, expiry, requestDescription);

    }

    function submitRFP(
        uint RFPId,
        string memory submissionDescription,
        address[] memory targets,
        uint256[] memory values,
        string[] memory signatures,
        bytes[] memory calldatas,
        string memory description
    ) external {

        //Require that the RFP is open
        require(requestForProposals[RFPId] == RFPStatus.open, "RFP is not open for submissions");

        Submission memory submission;

        uint256 currentSubCount = submissionCount;
        submissionCount++;

        submission.RFPId = RFPId;
        submission.submissionDescription = submissionDescription;
        submission.status = RFPSubmissionStatus.submitted;
        submission.targets = targets;
        submission.values = values;
        submission.signatures = signatures;
        submission.calldatas = calldatas;
        submission.description = description;

        submissions[RFPId][currentSubCount] = submission;

        emit SubmissionCreated(msg.sender, RFPId);

    }

    /**
    * @notice Cancel an existing Reuest for Proposal and receive bounty back
    * @notice This will need better reentrancy guards
    * @param id The ID of the Request for Proposal
    */
    function cancelRFP(uint id) external {
        //Require the msg.sender to be the RFP Creator
        require(requestsForProposals[id].requestor == msg.sender, "Only the RFP creator can cancel");
        //Require that the proposal has not alrady been paid out
        require(requestsForProposals[id].awarded == false, "RFP has already been paid out");

        //Add better re-entrancy guards
        uint256 payout = requestsForProposals[id].bounty;
        //set proposal bounty to zero
        requestsForProposals[id].bounty = 0;
        requestsForProposals[id].status = RFPStatus.cancelled;

        //Return funds
        IComp(comp).transferFrom(address(this), msg.sender, payout);

        emit RFPStatusChanged(id, RFPStatus.cancelled);
        
    }

/**
* @notice Award an RFP Submission
* @notice This will nee beter reentrancy guards
* @param rfpId The ID of the request for Proposal
* @param submissionId The ID of the submission to the RFP being awarded
 */
    function awardRFP(uint256 rfpId, uint256 submissionId) external {
        /// Required the creator of the RFP to award
        require(requestsForProposals[rfpId].requestor == msg.sender, "Only the RFP creator can award");
        /// Require the RFP is actually open
        require(requestsForProposals[rfpId].status == RFPStatus.open, "RFP is not open and can not be awarded");
        /// Require the RFP has not expired
        require(requestsForProposals[rfpId].expiry < Block.number, "RFP has expired");
        /// Require that the RFP proposal is "submitted"
        require(submissions[rfpId][submissionId].status == RFPSubmissionStatus.submitted, "RFP Proposal is not in Submitted State");
        
        requestsForProposals[rfpId].status = RFPStatus.awarded;
        submissions[rfpId][submissionId].status = RFPSubmissionStatus.selected;

        //Need better re-entrancy protection here. 
        uint256 bounty = requestsForProposals[id].bounty;
        requestsForProposals[rfpId].bounty = 0;
        
        //Send the bounty=, what happens if this fails?
        IComp(comp).transferFrom(address(this), submissions[rfpId][submissionId].creator, bounty);

        emit SubmissionChanged(rfpId, submissionId, submissions[rfpId][submissionId].status);

    }

    /**
    * @notice Submit an approved submission to the COMP CrowdProposalFactory
    * @notice Anyone can submit, but it must be an approved and paid out proposal
    * @notice The submiter must also have enough Comp allowance to succesfullly make the crowdProposal
    * @param rfpId The ID of the request for Proposal
    * @param submissionId The ID of the submission to the RFP being awarded
     */
    function submitToCAP(uint256 rfpId, uint256 submissionId) external {
        /// Require the Proposal to have been selected (maybe not nessesary but for now we let it slide)
        require(submissions[rfpId][submissionId].status == RFPSubmissionStatus.selected, "Proposal was not selected");

        //Mark Status as submitted (if anyone would reentrant this?)
        submissions[rfpId][submissionId].status = RFPSubmissionStatus.proposed;

        ICAPFactory(CAPFactory).createCrowdProposal(
            submissions[rfpId][submissionId].targets,
            submissions[rfpId][submissionId].values,
            submissions[rfpId][submissionId].signatures,
            submissions[rfpId][submissionId].calldatas,
            submissions[rfpId][submissionId].description,
        );

        emit SubmissionChanged(rfpId, submissionId,submissions[rfpId][submissionId].status);
    }

    //Todo
    //function getRFPStatus(uint256 RFPIs) public {}
    

    //function getProposalStatus() {}
}
