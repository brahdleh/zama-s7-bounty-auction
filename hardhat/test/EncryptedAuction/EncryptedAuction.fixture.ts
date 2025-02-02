import { ethers } from "hardhat";

import type { EncryptedAuction } from "../../types";
import { getSigners } from "../signers";

export async function deployEncryptedAuction(): Promise<EncryptedAuction> {

    const TOTAL_TOKENS = 1000;
    let startTime: number;
    let endTime: number;

    const signers = await getSigners();

    const currentBlock = await ethers.provider.getBlock("latest");
    startTime = currentBlock.timestamp + 1;
    endTime = currentBlock.timestamp + 1000;

    const contractFactory = await ethers.getContractFactory("EncryptedAuction");
    const contract = await contractFactory.connect(signers.alice).deploy(
        "Naraggara", 
        "NARA",
        TOTAL_TOKENS,
        startTime,
        endTime
    );
    await contract.waitForDeployment();

    return contract;
    }