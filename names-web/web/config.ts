import {hexToBytes} from "@noble/curves/utils"

export const chainId = 31337n
export const sponsor = hexToBytes("9a676e781a523b5d0c0e43731313a708cb607508")
export const resolver = hexToBytes("2279b7a0a67db372996a5fab50d91eaa73d2ebe6")
export const tld = "simplex"
export const duration = 2n * 365n * 24n * 3600n
