// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.5;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Manager is AccessControl, ReentrancyGuard, VRFConsumerBase, Ownable {
    ////////// CHAINLINK VRF v1 /////////////////
    bytes32 internal keyHash;
    uint256 internal fee;

    struct RandomResult {
        uint256 randomNumber; // random number generated by chainlink.
        uint256 nomalizedRandomNumber; // random number % entriesLength + 1
    }

    struct RaffleInfo {
        uint256 id; // raffleId
        uint256 size; // length of the entries array of that raffle
    }

    // event sent when the random number is generated by the VRF
    event RandomNumberCreated(
        uint256 indexed raffleId,
        uint256 randomNumber,
        uint256 normalizedRandomNumber
    );

    mapping(uint256 => RandomResult) public requests;
    // map the requestId created by chainlink with the raffle info passed as param when calling getRandomNumber()
    mapping(bytes32 => RaffleInfo) public chainlinkRaffleInfo;
    // Add a new mapping to store requestIds for each raffle
    mapping(uint256 => bytes32) private raffleRequestIds;

    /////////////// END CHAINKINK VRF V1 //////////////

    // Event sent when the raffle is created by the operator
    event RaffleCreated(
        uint256 indexed raffleId,
        address indexed nftAddress,
        uint256 indexed nftId
    );

    // Event sent when the owner of the nft stakes it for the raffle
    event RaffleStarted(uint256 indexed raffleId, address indexed seller);

    // Event sent when the raffle is finished
    event RaffleEnded(
        uint256 indexed raffleId,
        address indexed winner,
        uint256 amountRaised,
        uint256 randomNumber
    );

    // Event sent when one or more entry tickets are sold
    event EntrySold(
        uint256 indexed raffleId,
        address indexed buyer,
        uint256 currentSize
    );

    // Event sent when a free entry is added by the operator
    event FreeEntry(
        uint256 indexed raffleId,
        address[] buyer,
        uint256 amount,
        uint256 currentSize
    );

    // Event sent when a raffle is asked to cancel by the operator
    event RaffleCancelled(uint256 indexed raffleId, uint256 amountRaised);

    // The raffle is closed successfully and the platform receives the fee
    event FeeTransferredToPlatform(
        uint256 indexed raffleId,
        uint256 amountTransferred
    );
    // When the raffle is asked to be cancelled and 30 days have passed, the operator can call a method
    // to transfer the remaining funds and this event is emitted
    event RemainingFundsTransferred(
        uint256 indexed raffleId,
        uint256 amountInWeis
    );

    // When the raffle is asked to be cancelled and 30 days have not passed yet, the players can call a
    // method to refund the amount spent on the raffle and this event is emitted
    event Refund(
        uint256 indexed raffleId,
        uint256 amountInWeis,
        address indexed player
    );

    event SetWinnerTriggered(uint256 indexed raffleId, uint256 amountRaised);

    event StatusChangedInEmergency(uint256 indexed raffleId, uint256 newStatus);

    /* every raffle has an array of price structure with the different 
    prices for the different entries bought */
    struct PriceStructure {
        uint256 id;
        uint256 numEntries;
        uint256 price;
    }
    mapping(uint256 => PriceStructure[1]) public prices;

    // Every raffle has a funding structure.
    struct FundingStructure {
        uint256 minimumFundsInWeis;
    }
    mapping(uint256 => FundingStructure) public fundingList;

    // In order to calculate the winner, in this struct is saved for each bought the data
    struct EntriesBought {
        uint256 currentEntriesLength; // current amount of entries bought in the raffle
        address player; // wallet address of the player
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
        address winner; // address of the winner of the raffle. Address(0) if no winner yet
        uint256 randomNumber; // normalized (0-Entries array size) random number generated by the VRF
        uint256 amountRaised; // funds raised so far in wei
        address seller; // address of the seller of the NFT
        uint256 platformPercentage; // percentage of the funds raised that goes to the platform
        uint256 entriesLength; // the length of the entries array is saved here
        uint256 expiryTimeStamp;
    }

    // The main structure is an array of raffles
    RaffleStruct[] public raffles;

    // Map that contains the number of entries each user has bought, to prevent abuse, and the claiming info
    struct ClaimStruct {
        uint256 numEntriesPerUser;
        uint256 amountSpentInWeis;
        bool claimed;
    }
    mapping(bytes32 => ClaimStruct) public claimsData;

    // All the different status VRFCoordinator can have
    enum STATUS {
        CREATED, // the operator creates the raffle
        ACCEPTED, // the seller stakes the nft for the raffle
        EARLY_CASHOUT, // the seller wants to cashout early
        CANCELLED, // the operator cancels the raffle and transfer the remaining funds after 30 days passes
        CLOSING_REQUESTED, // the operator sets a winner
        ENDED, // the raffle is finished, and NFT and funds were transferred
        CANCEL_REQUESTED, // operator asks to cancel the raffle. Players has 30 days to ask for a refund
        CLOSING_FAILED // the operator failed to set a winner
    }

    // The operator role is operated by a backend application
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR");

    // address of the wallet controlled by the platform that will receive the platform fee
    address payable public destinationWallet =
        payable(0x520dcCE3c0d35804312c186DB4DB8d9249C4Ee5B);

    constructor(
        address _vrfCoordinator,
        address _linkToken,
        bytes32 _keyHash
    )
        VRFConsumerBase(
            _vrfCoordinator, // VRF Coordinator
            _linkToken // LINK Token
        )
    {
        _setupRole(
            OPERATOR_ROLE,
            address(0x11E7Fa3Bc863bceD1F1eC85B6EdC9b91FdD581CF)
        );
        _setupRole(
            DEFAULT_ADMIN_ROLE,
            address(0x11E7Fa3Bc863bceD1F1eC85B6EdC9b91FdD581CF)
        );

        keyHash = _keyHash;
        fee = 0.0001 * 10 ** 18; // in polygon, the fee must be 0.0001 LINK
    }

    /// @dev this is the method that will be called by the smart contract to get a random number
    /// @param _id Id of the raffle
    /// @param _entriesSize length of the entries array of that raffle
    /// @return requestId Id generated by chainlink
    function getRandomNumber(
        uint256 _id,
        uint256 _entriesSize
    ) internal returns (bytes32 requestId) {
        require(
            LINK.balanceOf(address(this)) >= fee,
            "Not enough LINK - please fund contract"
        );
        bytes32 result = requestRandomness(keyHash, fee);

        // result is the requestId generated by chainlink. It is saved in a map linked to the param id
        chainlinkRaffleInfo[result] = RaffleInfo({id: _id, size: _entriesSize});
        return result;
    }

    /// @dev Callback function used by VRF Coordinator. Is called by chainlink
    /// the random number generated is normalized to the size of the entries array, and an event is
    /// generated, that will be listened by the platform backend to be checked if corresponds to a
    /// particular raffle, and if true will call transferNFTAndFunds
    /// @param requestId id generated previously (on method getRandomNumber by chainlink)
    /// @param randomness random number (huge) generated by chainlink
    function fulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    ) internal override {
        // Get the raffle info from the map
        RaffleInfo memory raffleInfo = chainlinkRaffleInfo[requestId];

        // Check if the requestId has already been fulfilled
        if (raffles[raffleInfo.id].status == STATUS.ENDED) {
            return;
        }

        uint256 normalizedRandomNumber = (randomness % raffleInfo.size) + 1;

        // save the random number on the map with the original id as key
        RandomResult memory result = RandomResult({
            randomNumber: randomness,
            nomalizedRandomNumber: normalizedRandomNumber
        });

        requests[raffleInfo.id] = result;

        // send the event with the original id and the random number
        emit RandomNumberCreated(
            raffleInfo.id,
            randomness,
            normalizedRandomNumber
        );

        transferNFTAndFunds(raffleInfo.id, normalizedRandomNumber);
    }

    // The operator can call this method once they receive the event "RandomNumberCreated"
    // triggered by the VRF v1 consumer contract
    /// @param _raffleId Id of the raffle
    /// @param _normalizedRandomNumber index of the array that contains the winner of the raffle. Generated by chainlink
    /// @notice it is the method that sets the winner and transfers funds and nft
    /// @dev called by Chainlink callback function fulfillRandomness
    function transferNFTAndFunds(
        uint256 _raffleId,
        uint256 _normalizedRandomNumber
    ) internal nonReentrant {
        RaffleStruct storage raffle = raffles[_raffleId];

        // Only callable when the raffle is requested to be closed
        require(
            raffle.status == STATUS.EARLY_CASHOUT ||
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

        emit FeeTransferredToPlatform(_raffleId, amountForPlatform);

        emit RaffleEnded(
            _raffleId,
            raffle.winner,
            raffle.amountRaised,
            _normalizedRandomNumber
        );
    }

    // helper unction to view the current status of the raffle
    /// @param _raffleId Id of the raffle
    function getRaffleStatus(uint256 _raffleId) public view returns (STATUS) {
        RaffleStruct storage raffle = raffles[_raffleId];
        return raffle.status;
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
    /// @notice Creates a raffle
    /// @dev creates a raffle struct and push it to the raffles array. Some data is stored in the funding data structure
    /// sends an event when finished
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
            expiryTimeStamp: _expiryTimeStamp
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

    // helper method to get the winner address of a raffle
    /// @param _raffleId Id of the raffle
    /// @param _normalizedRandomNumber Generated by chainlink
    /// @return the wallet that won the raffle
    /// @dev Uses a binary search on the sorted array to retreive the winner address
    function getWinnerAddressFromRandom(
        uint256 _raffleId,
        uint256 _normalizedRandomNumber
    ) public view returns (address) {
        RaffleStruct storage raffle = raffles[_raffleId];

        uint256 position = findUpperBound(
            entriesList[_raffleId],
            _normalizedRandomNumber
        );

        address candidate = entriesList[_raffleId][position].player;
        // general case
        if (candidate != raffle.seller) return candidate;
        // special case. The user is blacklisted, so try next on the left until find a non-blacklisted
        else {
            bool ended = false;
            uint256 i = position;
            while (
                ended == false && entriesList[_raffleId][i].player == address(0)
            ) {
                if (i == 0) i = entriesList[_raffleId].length - 1;
                else i = i - 1;
                // we came to the beginning without finding a non blacklisted player
                if (i == position) ended == true;
            }
            return entriesList[_raffleId][i].player;
        }
    }

    /// @param array sorted array of EntriesBought. CurrentEntriesLength is the numeric field used to sort
    /// @param element uint256 to find. Goes from 1 to entriesLength
    /// @dev based on openzeppelin code (v4.0), modified to use an array of EntriesBought
    /// Searches a sorted array and returns the first index that contains a value greater or equal to element.
    /// If no such index exists (i.e. all values in the array are strictly less than element), the array length is returned. Time complexity O(log n).
    /// array is expected to be sorted in ascending order, and to contain no repeated elements.
    /// https://docs.openzeppelin.com/contracts/3.x/api/utils#Arrays-findUpperBound-uint256---uint256-
    function findUpperBound(
        EntriesBought[] storage array,
        uint256 element
    ) internal view returns (uint256) {
        if (array.length == 0) {
            return 0;
        }

        uint256 low = 0;
        uint256 high = array.length;

        while (low < high) {
            uint256 mid = Math.average(low, high);

            // Note that mid will always be strictly less than high (i.e. it will be a valid array index)
            // because Math.average rounds down (it does integer division with truncation).
            if (array[mid].currentEntriesLength > element) {
                high = mid;
            } else {
                low = mid + 1;
            }
        }

        // At this point `low` is the exclusive upper bound. We will return the inclusive upper bound.
        if (low > 0 && array[low - 1].currentEntriesLength == element) {
            return low - 1;
        } else {
            return low;
        }
    }

    // function to set the winner of a raffle. Technically anyone can call this function to trigger the chainlink VRF
    /// @param _raffleId Id of the raffle
    /// @dev it triggers Chainlink VRF1 consumer, and generates a random number that is normalized to the number of entries
    function setWinner(uint256 _raffleId) external nonReentrant {
        RaffleStruct storage raffle = raffles[_raffleId];
        FundingStructure storage funding = fundingList[_raffleId];

        require(
            raffle.status == STATUS.ACCEPTED ||
                raffle.status == STATUS.CLOSING_FAILED,
            "Raffle in wrong status"
        );
        require(
            raffle.expiryTimeStamp < block.timestamp,
            "Raffle not expired yet"
        );

        // Only update status if the request to Chainlink VRF is successful
        // TODO: this isn't working properly because sometimes the chainlink callback function is never executed.
        bytes32 requestId = getRandomNumber(_raffleId, raffle.entriesLength);
        if (requestId != bytes32(0)) {
            raffleRequestIds[_raffleId] = requestId;
            raffle.status = STATUS.CLOSING_REQUESTED;
            emit SetWinnerTriggered(_raffleId, raffle.amountRaised);
        } else {
            raffle.status = STATUS.CLOSING_FAILED;
        }
    }

    // function to manually set the winner of a raffle. Only callable by the owner
    // this is useful in case Chainlink VRF fails to generate a random number
    // and the raffle is stuck in CLOSING_REQUESTED status
    /// @param _raffleId Id of the raffle
    /// @param _normalizedRandomNumber random number we want to use to set the winner
    function transferNFTAndFundsEmergency(
        uint256 _raffleId,
        uint256 _normalizedRandomNumber
    ) public nonReentrant onlyOwner {
        RaffleStruct storage raffle = raffles[_raffleId];

        // Only callable when the raffle is requested to be closed
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

        emit FeeTransferredToPlatform(_raffleId, amountForPlatform);

        emit RaffleEnded(
            _raffleId,
            raffle.winner,
            raffle.amountRaised,
            _normalizedRandomNumber
        );
    }

    // this is the method to be called by the owner to re-trigger getting a random
    // number when the raffle is stuck in CLOSING_REQUESTED status because the
    // Chainlink VRF callback function was never executed
    /// @param _id Id of the raffle
    /// @return requestId Id generated by chainlink
    function getRandomNumberEmergency(
        uint256 _id
    ) public returns (bytes32 requestId) {
        RaffleStruct storage raffle = raffles[_id];

        require(
            LINK.balanceOf(address(this)) >= fee,
            "Not enough LINK - please fund contract"
        );
        require(
            raffle.status == STATUS.CLOSING_REQUESTED,
            "Raffle in wrong status"
        );
        bytes32 result = requestRandomness(keyHash, fee);

        // result is the requestId generated by chainlink. It is saved in a map linked to the param id
        chainlinkRaffleInfo[result] = RaffleInfo({
            id: _id,
            size: raffle.entriesLength
        });
        return result;
    }
}
