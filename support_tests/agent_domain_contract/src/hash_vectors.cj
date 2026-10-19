package agent_domain_contract

import agent_domain.*

// Fixed independent SHA-256 digests. The text vectors include the standard
// empty, abc, 56-byte multi-block and million-a examples. Binary boundary and
// 1-MiB digests were checked with Python hashlib, not this implementation.
func assertModelPolicySha256Vectors(): Unit {
    expect(modelPolicySha256Text("") ==
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "SHA-256 empty message known digest")
    expect(modelPolicySha256Text("abc") ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        "SHA-256 abc known digest")
    expect(modelPolicySha256Text("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
        "SHA-256 standard 56-byte multi-block known digest")
    let sizes: Array<Int64> = [55, 56, 63, 64, 65]
    let expected = [
        "2900465fcb533e05a158fd2b3be0e5e3b03740d83060aa3580e0d98a96bf2384",
        "31454ff48ef36af2f08fd511bdc37d9d5855ac23e992e5ff5445cb6b7674a674",
        "5f6401b96532c36de4e65beec0409b69b1d181864c8009b7a04f43e5d56350d1",
        "94eb5de4943613fd048dc93393ab06877405faa39c11f53e9386083339833e7e",
        "fc518669b6eb4b4dd91827ecacef86689c725bd5bab888fd3b26dbb196eec954",
    ]
    for (index in 0..sizes.size) {
        expect(modelPolicySha256(sha256ContractBinary(sizes[index])) == expected[index],
            "SHA-256 binary padding boundary digest")
    }
    expect(modelPolicySha256(sha256ContractBinary(1048576)) ==
        "3a814d27145f9540c495715da2f85208f3805c323d7da3e9867df2992be4432d",
        "SHA-256 1-MiB binary digest keeps every input byte")
    expect(modelPolicySha256(Array<Byte>(1000000, repeat: 97u8)) ==
        "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
        "SHA-256 standard million-a known digest")
}

func sha256ContractBinary(size: Int64): Array<Byte> {
    let bytes = Array<Byte>(size, repeat: 0u8)
    for (index in 0..size) { bytes[index] = UInt8((index * 37 + 11) % 256) }
    bytes
}
