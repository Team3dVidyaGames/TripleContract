const Inventory = artifacts.require("Inventory");
const RNG = artifacts.require("RandomNumberGenerator");
const TripleTriad = artifacts.require("TripleTriad");

const { assert } = require("chai");
const { BN } = require("web3-utils");
const timeMachine = require('ganache-time-traveler');

contract("Triple Triad", (accounts) => {
    let rng_contract, inventory_contract, triple_contract;

    before(async () => {
        await Inventory.new(
            "https://team3d.io/inventory/json/",
            ".json",
            "0x3D3D35bb9bEC23b06Ca00fe472b50E7A4c692C30",
            { from: accounts[0] }
        ).then((instance) => {
            inventory_contract = instance;
        });

        await RNG.new(
            "0xdD3782915140c8f3b190B5D67eAc6dc5760C46E9",   // Chainlink VRF Coordinator address
            "0xa36085F69e2889c224210F603D836748e7dC0088",   // LINK token address
            "0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4",   // Key Hash
            1, // fee
            { from: accounts[0] }
        ).then((instance) => {
            rng_contract = instance;
        });

        await TripleTriad.new(
            inventory_contract.address,
            rng_contract.address,
            1,
            50,
            100,
            { from: accounts[0] }
        ).then((instance) => {
            triple_contract = instance;
        });

    });

    describe("Starter Pack", () => {
        it("Pack is not opened without ranks", async () => {
            let thrownError;
            try {
                await triple_contract.openStarterPack(
                    { from: accounts[0] }
                );
            } catch (error) {
                thrownError = error;
            }

            assert.include(
                thrownError.message,
                'Triple Triad: Admin has not added ranks yet',
            )
        });

        // it("Starter Pack is working", async () => {
        //     await triple_contract.addRanks([[51, 1, 2, 3, 4], [52, 3, 4, 1, 1], [53, 5, 1, 2, 3], [54, 3, 1, 5, 7], [55, 5, 2, 1, 4],
        //         [56, 4, 3, 2, 1], [57, 4, 2, 3, 4]], [58, 5, 5, 4, 4], [59, 1, 1, 1, 4], [60, 3, 2, 1, 4], { from: accounts[0] });
        

        //     await triple_contract.bet(40, new BN('100000000000000000000'), { from: accounts[1] }); // Bet Number: 40, Bet Amount: 100 GBTS
        //     assert.equal(new BN(await gbts_contract.balanceOf(ulp_contract.address)).toString(), new BN('101100000000000000000000').toString());
        // });

    });

});
