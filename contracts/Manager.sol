// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.5;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

contract Manager is
    AccessControl,
    ReentrancyGuard,
    VRFConsumerBaseV2,
    ConfirmedOwner
{
    struct RaffleInfo {
        uint256 id;
        uint256 size;
    }

    // map the requestId created by chainlink with the raffle info passed as param when calling requestRandomWords()
    mapping(uint256 => RaffleInfo) public chainlinkRaffleInfo;

    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed nftAddress,
        uint256 indexed nftId
    );

    event RaffleStarted(uint256 indexed raffleId, address indexed seller);

    event RaffleEnded(
        uint256 indexed raffleId,
        address indexed winner,
        uint256 amountRaised,
        uint256 randomNumber
    );

    event EntrySold(
        uint256 indexed raffleId,
        address indexed buyer,
        uint256 currentSize
    );

    event FreeEntry(
        uint256 indexed raffleId,
        address[] buyer,
        uint256 amount,
        uint256 currentSize
    );

    event RaffleCancelled(uint256 indexed raffleId, uint256 amountRaised);

    event SetWinnerTriggered(uint256 indexed raffleId, uint256 amountRaised);

    event RequestSent(uint256 requestId, uint32 numWords);

    event RequestFulfilled(
        uint256 requestId,
        uint256[] randomWords,
        uint256 raffleId
    );

    struct RequestStatus {
        bool fulfilled; // whether the request has been successfully fulfilled
        bool exists; // whether a requestId exists
        uint256[] randomWords;
    }
    mapping(uint256 => RequestStatus)
        public s_requests; /* requestId --> requestStatus */

    struct PriceStructure {
        uint256 id;
        uint256 numEntries;
        uint256 price;
    }
    mapping(uint256 => PriceStructure[1]) public prices;

    struct FundingStructure {
        uint256 minimumFundsInWeis;
    }
    mapping(uint256 => FundingStructure) public fundingList;

    struct EntriesBought {
        uint256 currentEntriesLength;
        address player;
    }

    // every raffle has a sorted array of EntriesBought. Each element is created when calling
    // either buyEntry or giveBatchEntriesForFree
    mapping(uint256 => EntriesBought[]) public entriesList;

    // Main raffle data struct
    struct RaffleStruct {
        STATUS status; // status of the raffle. Can be created, accepted, ended, etc
        uint256 maxEntries; // maximum number of entries, aka total ticket supply
        address collateralAddress; // address of the NFT
        uint256 collateralId; // NFT id of the collateral NFT
        address winner; // address of the winner of the raffle. Default to seller if no tickets bought
        uint256 randomNumber; // normalized (0-Entries array size) random number generated by the VRF
        uint256 amountRaised; // funds raised so far in wei
        address seller; // address of the seller of the NFT
        uint256 platformPercentage; // percentage of the funds raised that goes to the platform
        uint256 entriesLength; // the length of the entries array is saved here
        uint256 expiryTimeStamp; // end date of the raffle
        bool randomNumberAvailable;
    }

    // The main structure is an array of raffles
    RaffleStruct[] public raffles;

    struct ClaimStruct {
        uint256 numEntriesPerUser;
        uint256 amountSpentInWeis;
        bool claimed;
    }
    mapping(bytes32 => ClaimStruct) public claimsData;

    mapping(uint256 => mapping(address => uint256))
        public raffleCumulativeEntries;

    // All the different status VRFCoordinator can have
    enum STATUS {
        CREATED, // the operator creates the raffle
        ACCEPTED, // the seller stakes the nft for the raffle
        EARLY_CASHOUT, // the seller wants to cashout early
        CANCELLED, // the operator cancels the raffle and transfer the remaining funds after 30 days passes
        CLOSING_REQUESTED, // the operator sets a winner
        ENDED, // the raffle is finished, and NFT and funds were transferred
        CANCEL_REQUESTED // operator asks to cancel the raffle. Players has 30 days to ask for a refund
    }

    // The operator role is operated by a backend application
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    // address of the wallet controlled by the platform that will receive the platform fee
    address payable public destinationWallet =
        payable(0x520dcCE3c0d35804312c186DB4DB8d9249C4Ee5B);

    VRFCoordinatorV2Interface COORDINATOR;

    // Your VRF V2 coordinator subscription ID.
    uint64 s_subscriptionId;

    // past requests Id.
    uint256[] public requestIds;
    uint256 public lastRequestId;

    bytes32 keyHash =
        0xd729dc84e21ae57ffb6be0053bf2b0668aa2aaf300a2a7b2ddf7dc0bb6e875a8;
    uint32 callbackGasLimit = 2500000;
    uint16 requestConfirmations = 3;
    uint32 numWords = 1;

    constructor(
        uint64 subscriptionId
    )
        VRFConsumerBaseV2(0xAE975071Be8F8eE67addBC1A82488F1C24858067)
        ConfirmedOwner(msg.sender)
    {
        COORDINATOR = VRFCoordinatorV2Interface(
            0xAE975071Be8F8eE67addBC1A82488F1C24858067
        );
        s_subscriptionId = subscriptionId;
        _setupRole(
            OPERATOR_ROLE,
            address(0x11E7Fa3Bc863bceD1F1eC85B6EdC9b91FdD581CF)
        );
        _setupRole(
            DEFAULT_ADMIN_ROLE,
            address(0x11E7Fa3Bc863bceD1F1eC85B6EdC9b91FdD581CF)
        );
    }

    // this function is called during setWinner. It will request a random number from the VRF
    // and save the raffleId and the number of entries in the raffle in a map. If a request is
    // successful, the callback function, fulfillRandomWords will be called.
    /// @param _id is the raffleID
    /// @param _entriesSize is the number of entries in the raffle
    /// @return requestId is the requestId generated by chainlink
    function requestRandomWords(
        uint256 _id,
        uint256 _entriesSize
    ) internal returns (uint256 requestId) {
        // Will revert if subscription is not set and funded.
        requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            numWords
        );
        s_requests[requestId] = RequestStatus({
            randomWords: new uint256[](0),
            exists: true,
            fulfilled: false
        });

        requestIds.push(requestId);
        lastRequestId = requestId;

        // result is the requestId generated by chainlink. It is saved in a map linked to the param id
        chainlinkRaffleInfo[requestId] = RaffleInfo({
            id: _id,
            size: _entriesSize
        });
        emit RequestSent(requestId, numWords);
        return requestId;
    }

    // This is the callback function called by the VRF when the random number is ready.
    // It will emit an event with the original raffleId and the random number. It then
    // calls transferNFTAndFunds to transfer the NFT and the funds to the winner
    /// @param _requestId is the requestId generated by chainlink
    /// @param _randomWords is the random number generated by the VRF
    function fulfillRandomWords(
        uint256 _requestId,
        uint256[] memory _randomWords
    ) internal override {
        require(s_requests[_requestId].exists, "request not found");
        s_requests[_requestId].fulfilled = true;
        s_requests[_requestId].randomWords = _randomWords;
        RaffleInfo memory raffleInfo = chainlinkRaffleInfo[_requestId];
        uint256 normalizedRandomNumber = (_randomWords[0] % raffleInfo.size) +
            1;
        raffles[raffleInfo.id].randomNumber = normalizedRandomNumber;
        raffles[raffleInfo.id].randomNumberAvailable = true;
        emit RequestFulfilled(_requestId, _randomWords, raffleInfo.id);
    }

    // modifier for transferNFTAndFunds. It will check that the caller is the owner or the seller
    /// @param _raffleId is the raffleId
    modifier onlyTrustedCaller(uint256 _raffleId) {
        RaffleStruct storage raffle = raffles[_raffleId];
        require(
            msg.sender == owner() || msg.sender == raffle.seller, // Add other trusted parties if necessary
            "Caller not authorized"
        );
        _;
    }

    // triggered by the VRF callback function fulfillRandomWords, it will transfer the NFT
    // to the winner and the funds to the seller
    /// @param _raffleId Id of the raffle
    function transferNFTAndFunds(
        uint256 _raffleId
    ) external nonReentrant onlyTrustedCaller(_raffleId) {
        RaffleStruct storage raffle = raffles[_raffleId];
        // Check that the random number is available and the raffle is in the correct state
        require(
            raffle.randomNumberAvailable &&
                raffle.status == STATUS.CLOSING_REQUESTED,
            "Raffle in wrong status or random number not available"
        );
        raffle.winner = (raffle.amountRaised == 0)
            ? raffle.seller
            : getWinnerAddressFromRandom(_raffleId, raffle.randomNumber);

        IERC721(raffle.collateralAddress).transferFrom(
            address(this),
            raffle.winner,
            raffle.collateralId
        );

        uint256 amountForPlatform = (raffle.amountRaised *
            raffle.platformPercentage) / 10000;
        uint256 amountForSeller = raffle.amountRaised - amountForPlatform;

        // transfer 95% to the seller
        (bool sent, ) = raffle.seller.call{value: amountForSeller}("");
        require(sent, "Failed to send Ether to seller");

        // transfer 5% to the platform
        (bool sent2, ) = destinationWallet.call{value: amountForPlatform}("");
        require(sent2, "Failed to send Ether to platform");

        raffle.status = STATUS.ENDED;
        raffle.randomNumberAvailable = false;

        emit RaffleEnded(
            _raffleId,
            raffle.winner,
            raffle.amountRaised,
            raffle.randomNumber
        );
    }

    // helper unction to view the current status of the raffle
    /// @param _raffleId Id of the raffle
    /// @return status of the raffle
    function getRaffleStatus(uint256 _raffleId) public view returns (STATUS) {
        RaffleStruct storage raffle = raffles[_raffleId];
        return raffle.status;
    }

    // helper unction to get the status of the chainlink request
    /// @param _requestId Id of the request
    /// @return fulfilled status of the request
    /// @return randomWords random number generated by the VRF
    function getRequestStatus(
        uint256 _requestId
    ) external view returns (bool fulfilled, uint256[] memory randomWords) {
        require(s_requests[_requestId].exists, "request not found");
        RequestStatus memory request = s_requests[_requestId];
        return (request.fulfilled, request.randomWords);
    }

    // helper function to get the length of entriesList for a raffle
    /// @param _raffleId Id of the raffle
    /// @return length of the entriesList
    function getEntriesSize(uint256 _raffleId) public view returns (uint256) {
        return entriesList[_raffleId].length;
    }

    // helper function to get the raffle randomNumberAvailable bool for a raffle
    /// @param _raffleId Id of the raffle
    /// @return randomNumberAvailable bool
    function getRandomNumberAvailable(
        uint256 _raffleId
    ) public view returns (bool) {
        return raffles[_raffleId].randomNumberAvailable;
    }

    // helper function to get the raffle randomNumber for a raffle
    /// @param _raffleId Id of the raffle
    /// @return randomNumber
    function getRaffleRandomNumber(
        uint256 _raffleId
    ) public view returns (uint256) {
        return raffles[_raffleId].randomNumber;
    }

    // helper function for onlyOwner to extract the NFT from the contract
    // in the case of a failed raffle. This is to avoid the NFT being stuck in the contract
    // if the chainlink callback function does not exectute as expected
    /// @param _raffleId Id of the raffle
    function extractNFT(uint256 _raffleId) public onlyOwner {
        RaffleStruct storage raffle = raffles[_raffleId];
        require(raffle.collateralId != 0, "Raffle collateralId is not set");
        require(
            raffle.collateralAddress != address(0),
            "Raffle collateralAddress is not set"
        );
        IERC721(raffle.collateralAddress).safeTransferFrom(
            address(this),
            owner(),
            raffle.collateralId
        );
    }

    // helper function for onlyOwner to extract the funds from the contract
    // in the case of a failed raffle. This is to avoid the funds being stuck in the contract
    // if the chainlink callback function does not exectute as expected
    /// @param _raffleId Id of the raffle
    function extractFunds(uint256 _raffleId) public payable onlyOwner {
        RaffleStruct storage raffle = raffles[_raffleId];
        require(raffle.collateralId != 0, "Raffle collateralId is not set");
        require(
            raffle.collateralAddress != address(0),
            "Raffle collateralAddress is not set"
        );

        payable(owner()).transfer(raffle.amountRaised);
    }

    // helper function to get the number of all the entries bought for a
    // particular raffle
    /// @param _raffleId Id of the raffle
    /// @return entriesLength length of entries
    function getNumberOfEntries(
        uint256 _raffleId
    ) public view returns (uint256) {
        RaffleStruct storage raffle = raffles[_raffleId];
        return raffle.entriesLength;
    }

    // helper function to get all of the raffle struct data
    // for a particular raffle Id
    /// @param _raffleId Id of the raffle
    function getRaffle(
        uint256 _raffleId
    )
        public
        view
        returns (
            STATUS,
            uint256,
            address,
            uint256,
            address,
            uint256,
            uint256,
            address,
            uint256,
            uint256,
            uint256
        )
    {
        RaffleStruct storage raffle = raffles[_raffleId];
        return (
            raffle.status,
            raffle.amountRaised,
            raffle.collateralAddress,
            raffle.collateralId,
            raffle.seller,
            raffle.entriesLength,
            raffle.randomNumber,
            raffle.winner,
            raffle.platformPercentage,
            raffle.expiryTimeStamp,
            raffle.maxEntries
        );
    }

    // function to create a raffle
    /// @param _collateralAddress The address of the NFT of the raffle
    /// @param _collateralId The id of the NFT (ERC721)
    /// @param _prices Array of prices and amount of entries the customer could purchase
    /// @return raffleId
    function createRaffle(
        uint256 _maxEntries,
        address _collateralAddress,
        uint256 _collateralId,
        uint256 _pricePerTicketInWeis,
        PriceStructure[] calldata _prices,
        address _raffleCreator,
        uint256 _expiryTimeStamp
    ) external returns (uint256) {
        uint256 _minimumFundsInWeis = 1; //TODO what is the impact of this
        uint _commissionInBasicPoints = 500;

        require(_collateralAddress != address(0), "NFT is null");
        require(_collateralId != 0, "NFT id is null");
        require(_maxEntries > 0, "Max entries is needs to be greater than 0");

        /* instantiate the raffle struct and push it to the raffles array
         the winner defaults to the raffle creator if no one buys a ticket */
        RaffleStruct memory raffle = RaffleStruct({
            status: STATUS.CREATED,
            maxEntries: _maxEntries,
            collateralAddress: _collateralAddress,
            collateralId: _collateralId,
            winner: _raffleCreator,
            randomNumber: 0,
            amountRaised: 0,
            seller: _raffleCreator,
            platformPercentage: _commissionInBasicPoints,
            entriesLength: 0,
            expiryTimeStamp: _expiryTimeStamp,
            randomNumberAvailable: false
        });

        raffles.push(raffle);

        PriceStructure memory p = PriceStructure({
            id: _prices[0].id,
            numEntries: _maxEntries,
            price: _pricePerTicketInWeis
        });

        uint raffleID = raffles.length - 1;
        prices[raffleID][0] = p;

        fundingList[raffleID] = FundingStructure({
            minimumFundsInWeis: _minimumFundsInWeis
        });

        emit RaffleCreated(raffleID, _collateralAddress, _collateralId);

        stakeNFT(raffleID);
        return raffleID;
    }

    // function for the creator of the raffle to stake the NFT
    // the NFT is transferred to the contract and the status of the raffle is set to ACCEPTED
    /// @param _raffleId Id of the raffle
    function stakeNFT(uint256 _raffleId) internal {
        RaffleStruct storage raffle = raffles[_raffleId];

        // ensure the raffle is in the CREATED state. This should be the next state after the raffle is created
        require(raffle.status == STATUS.CREATED, "Raffle not CREATED");

        IERC721 token = IERC721(raffle.collateralAddress);
        require(
            token.ownerOf(raffle.collateralId) == msg.sender,
            "NFT is not owned by caller"
        );

        raffle.status = STATUS.ACCEPTED;
        token.transferFrom(msg.sender, address(this), raffle.collateralId); // transfer the token to the contract

        emit RaffleStarted(_raffleId, msg.sender);
    }

    /// function to buy a ticket for a raffle. The user can buy multiple tickets at once
    /// As the method is payable, in msg.value there will be the amount paid by the user
    /// @param _raffleId: id of the raffle
    /// @param _numberOfTickets: number of tickets the user wants to buy
    function buyEntry(
        uint256 _raffleId,
        uint256 _numberOfTickets
    ) external payable nonReentrant {
        RaffleStruct storage raffle = raffles[_raffleId];
        PriceStructure memory priceStruct = getPriceStructForId(_raffleId);

        require(
            raffle.seller != msg.sender,
            "The seller cannot buy his/her own tickets"
        );
        require(msg.sender != address(0), "msg.sender is null");
        require(
            raffle.status == STATUS.ACCEPTED,
            "Raffle is not in accepted. AKA the NFT was never staked / sent to the contract"
        );
        require(raffle.expiryTimeStamp > block.timestamp, "Raffle has expired");
        require(
            raffle.entriesLength < raffle.maxEntries,
            "Raffle has reached max entries"
        );
        require(priceStruct.numEntries > 0, "priceStruct.numEntries");
        require(
            _numberOfTickets <= priceStruct.numEntries,
            "buying more than the maximum tickets"
        );
        require(
            msg.value == _numberOfTickets * priceStruct.price,
            "msg.value must be equal to the price * number of tickets"
        );

        bytes32 hash = keccak256(abi.encode(msg.sender, _raffleId));

        EntriesBought memory entryBought = EntriesBought({
            player: msg.sender,
            currentEntriesLength: _numberOfTickets
        });
        entriesList[_raffleId].push(entryBought);

        // update raffle data
        raffle.amountRaised += msg.value;
        raffle.entriesLength = raffle.entriesLength + _numberOfTickets;

        //update claim data
        claimsData[hash].numEntriesPerUser += priceStruct.numEntries;
        claimsData[hash].amountSpentInWeis += msg.value;

        emit EntrySold(_raffleId, msg.sender, _numberOfTickets);
    }

    // helper function to get the price structure for a given raffle
    /// @param _idRaffle: id of the raffle
    /// @return priceStruct: price structure for the raffle
    function getPriceStructForId(
        uint256 _idRaffle
    ) internal view returns (PriceStructure memory) {
        return prices[_idRaffle][0];
    }

    function getWinnerAddressFromRandom(
        uint256 _raffleId,
        uint256 _normalizedRandomNumber
    ) public view returns (address) {
        uint256 cumulativeSum = 0;
        address winner;

        RaffleStruct storage raffle = raffles[_raffleId];
        EntriesBought[] storage entries = entriesList[_raffleId];
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].player == raffle.seller) {
                continue; // Skip the seller's entry
            }

            cumulativeSum += entries[i].currentEntriesLength;

            if (cumulativeSum >= _normalizedRandomNumber) {
                winner = entries[i].player;
                break;
            }
        }

        require(winner != address(0), "Winner not found");
        return winner;
    }

    // function to set the winner of a raffle. Technically anyone can call this function to trigger the chainlink VRF
    /// @param _raffleId Id of the raffle
    function setWinner(uint256 _raffleId) external nonReentrant {
        RaffleStruct storage raffle = raffles[_raffleId];

        require(raffle.status == STATUS.ACCEPTED, "Raffle in wrong status");
        require(
            raffle.expiryTimeStamp < block.timestamp,
            "Raffle not expired yet"
        );

        requestRandomWords(_raffleId, raffle.entriesLength);
        raffle.status = STATUS.CLOSING_REQUESTED;
        emit SetWinnerTriggered(_raffleId, raffle.amountRaised);
    }

    // function to manually set the winner of a raffle. Only callable by the owner
    // this is useful in case Chainlink VRF fails to generate a random number
    // and we want to generate randomness off-chain as a last resort
    /// @param _raffleId Id of the raffle
    /// @param _normalizedRandomNumber random number we want to use to set the winner
    function transferNFTAndFundsEmergency(
        uint256 _raffleId,
        uint256 _normalizedRandomNumber
    ) public nonReentrant onlyOwner {
        RaffleStruct storage raffle = raffles[_raffleId];

        require(
            raffle.status == STATUS.CLOSING_REQUESTED,
            "Raffle in wrong status"
        );

        raffle.randomNumber = _normalizedRandomNumber;

        if (raffle.amountRaised == 0) {
            raffle.winner = raffle.seller;
        } else {
            raffle.winner = getWinnerAddressFromRandom(
                _raffleId,
                _normalizedRandomNumber
            );
        }

        IERC721 _asset = IERC721(raffle.collateralAddress);
        _asset.transferFrom(address(this), raffle.winner, raffle.collateralId); // transfer the NFT to the winner

        uint256 amountForPlatform = (raffle.amountRaised *
            raffle.platformPercentage) / 10000;
        uint256 amountForSeller = raffle.amountRaised - amountForPlatform;

        // transfer 95% to the seller
        (bool sent, ) = raffle.seller.call{value: amountForSeller}("");
        require(sent, "Failed to send Ether");

        // transfer 5% to the platform
        (bool sent2, ) = destinationWallet.call{value: amountForPlatform}("");
        require(sent2, "Failed send Eth to MW");

        raffle.status = STATUS.ENDED;

        emit RaffleEnded(
            _raffleId,
            raffle.winner,
            raffle.amountRaised,
            _normalizedRandomNumber
        );
    }

    // The operator can add free entries to the raffle
    /// @param _raffleId Id of the raffle
    /// @param _freePlayers array of addresses corresponding to the wallet of the users that won a free entrie
    /// @dev only operator can make this call. Assigns a single entry per user, except if that user already reached the max limit of entries per user
    function giveBatchEntriesForFree(
        uint256 _raffleId,
        address[] memory _freePlayers
    ) external nonReentrant onlyRole(OPERATOR_ROLE) {
        require(
            raffles[_raffleId].status == STATUS.ACCEPTED,
            "Raffle is not in accepted"
        );

        uint256 freePlayersLength = _freePlayers.length;
        uint256 validPlayersCount = 0;

        for (uint256 i = 0; i < freePlayersLength; i++) {
            address entry = _freePlayers[i];
            EntriesBought memory entryBought = EntriesBought({
                player: entry,
                currentEntriesLength: 1
            });
            entriesList[_raffleId].push(entryBought);

            claimsData[keccak256(abi.encode(entry, _raffleId))]
                .numEntriesPerUser++; // needed?

            ++validPlayersCount;
        }

        raffles[_raffleId].entriesLength =
            raffles[_raffleId].entriesLength +
            validPlayersCount;

        emit FreeEntry(
            _raffleId,
            _freePlayers,
            freePlayersLength,
            raffles[_raffleId].entriesLength
        );
    }
}
