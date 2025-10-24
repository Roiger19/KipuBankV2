// La ruta de importación vuelve a ser '/modules'
import { buildModule } from "@nomicfoundation/hardhat-ignition/modules"; 
import { ethers } from "ethers";

// Deploy Module for KipuBankV2
// El nombre de la función sigue siendo 'buildModule'
const KipuBankV2Module = buildModule("KipuBankV2Module", (m) => {
  
  // --- Define the Constructor Arguments ---
  
  // Cap of 10,000 USD (with 8 decimals)
  const initialBankCapUsd = m.getParameter(
    "initialBankCapUsd",
    ethers.parseUnits("10000", 8) 
  );

  // Limit of 500 USD per withdrawal (with 8 decimals)
  const initialMaxWithdrawUsd = m.getParameter(
    "initialMaxWithdrawUsd",
    ethers.parseUnits("500", 8)
  );

  // Deploy the contract
  const kipuBank = m.contract("KipuBankV2", [
    initialBankCapUsd,
    initialMaxWithdrawUsd,
  ]);

  return { kipuBank };
});

export default KipuBankV2Module;