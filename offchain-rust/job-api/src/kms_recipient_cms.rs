const MAX_CMS_BYTES: usize = 1024 * 1024;
const MAX_ASN1_DEPTH: usize = 16;

const OID_PKCS7_ENVELOPED_DATA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x03];
const OID_PKCS7_DATA: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01];
const OID_RSAES_OAEP: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x07];
const OID_MGF1: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x08];
const OID_PSPECIFIED: &[u8] = &[0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x09];
const OID_SHA256: &[u8] = &[0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01];
const OID_AES_256_CBC: &[u8] = &[0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a];

#[derive(Debug, PartialEq, Eq)]
pub struct KmsRecipientEnvelope {
    pub encrypted_key: Vec<u8>,
    pub iv: Vec<u8>,
    pub ciphertext: Vec<u8>,
}

#[cfg(feature = "worker")]
pub fn decrypt_kms_recipient_envelope(
    private_key: &rsa::RsaPrivateKey,
    envelope: &KmsRecipientEnvelope,
) -> Result<zeroize::Zeroizing<Vec<u8>>, &'static str> {
    use cbc::cipher::{BlockDecryptMut, KeyIvInit, block_padding::Pkcs7};
    use rsa::Oaep;
    use sha2::Sha256;

    let symmetric_key = zeroize::Zeroizing::new(
        private_key
            .decrypt(Oaep::new::<Sha256>(), &envelope.encrypted_key)
            .map_err(|_| "RSA_UNWRAP_FAILED")?,
    );
    if symmetric_key.len() != 32 || envelope.iv.len() != 16 {
        return Err("CMS_KEY_OR_IV_LENGTH");
    }
    let mut plaintext = zeroize::Zeroizing::new(envelope.ciphertext.clone());
    let plaintext_len =
        cbc::Decryptor::<aes::Aes256>::new_from_slices(symmetric_key.as_slice(), &envelope.iv)
            .map_err(|_| "CMS_KEY_OR_IV_LENGTH")?
            .decrypt_padded_mut::<Pkcs7>(plaintext.as_mut_slice())
            .map_err(|_| "CMS_CONTENT_DECRYPT_FAILED")?
            .len();
    plaintext.truncate(plaintext_len);
    Ok(plaintext)
}

#[derive(Clone, Copy)]
struct Tlv<'a> {
    tag: u8,
    content: &'a [u8],
}

struct Reader<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    fn new(input: &'a [u8]) -> Self {
        Self { input, offset: 0 }
    }

    fn is_empty(&self) -> bool {
        self.offset == self.input.len()
    }

    fn peek_tag(&self) -> Option<u8> {
        self.input.get(self.offset).copied()
    }

    fn read(&mut self) -> Result<Tlv<'a>, &'static str> {
        let (value, next) = parse_tlv_at(self.input, self.offset, 0)?;
        self.offset = next;
        Ok(value)
    }

    fn expect(&mut self, tag: u8) -> Result<Tlv<'a>, &'static str> {
        let value = self.read()?;
        if value.tag != tag {
            return Err("CMS_ASN1_TAG");
        }
        Ok(value)
    }
}

fn parse_tlv_at(
    input: &[u8],
    offset: usize,
    depth: usize,
) -> Result<(Tlv<'_>, usize), &'static str> {
    if depth >= MAX_ASN1_DEPTH || offset >= input.len() {
        return Err("CMS_ASN1_DEPTH_OR_EOF");
    }
    let tag = input[offset];
    if tag & 0x1f == 0x1f {
        return Err("CMS_ASN1_HIGH_TAG");
    }
    let length_offset = offset.checked_add(1).ok_or("CMS_ASN1_OVERFLOW")?;
    let first = *input.get(length_offset).ok_or("CMS_ASN1_EOF")?;
    let content_start;
    let content_end;
    let next;
    if first == 0x80 {
        if tag & 0x20 == 0 {
            return Err("CMS_ASN1_INDEFINITE_PRIMITIVE");
        }
        content_start = length_offset + 1;
        let mut cursor = content_start;
        loop {
            if input.get(cursor..cursor + 2) == Some(&[0, 0]) {
                content_end = cursor;
                next = cursor + 2;
                break;
            }
            let (_, nested_next) = parse_tlv_at(input, cursor, depth + 1)?;
            cursor = nested_next;
        }
    } else {
        let (length, header_bytes) = if first & 0x80 == 0 {
            (usize::from(first), 1usize)
        } else {
            let count = usize::from(first & 0x7f);
            if count == 0 || count > 4 {
                return Err("CMS_ASN1_LENGTH");
            }
            let length_bytes = input
                .get(length_offset + 1..length_offset + 1 + count)
                .ok_or("CMS_ASN1_EOF")?;
            if length_bytes[0] == 0 {
                return Err("CMS_ASN1_NON_MINIMAL_LENGTH");
            }
            let mut length = 0usize;
            for byte in length_bytes {
                length = length
                    .checked_mul(256)
                    .and_then(|value| value.checked_add(usize::from(*byte)))
                    .ok_or("CMS_ASN1_OVERFLOW")?;
            }
            (length, 1 + count)
        };
        content_start = length_offset
            .checked_add(header_bytes)
            .ok_or("CMS_ASN1_OVERFLOW")?;
        content_end = content_start
            .checked_add(length)
            .ok_or("CMS_ASN1_OVERFLOW")?;
        if content_end > input.len() {
            return Err("CMS_ASN1_EOF");
        }
        next = content_end;
    }
    Ok((
        Tlv {
            tag,
            content: &input[content_start..content_end],
        },
        next,
    ))
}

fn expect_oid(reader: &mut Reader<'_>, expected: &[u8]) -> Result<(), &'static str> {
    if reader.expect(0x06)?.content != expected {
        return Err("CMS_OID");
    }
    Ok(())
}

fn expect_version(reader: &mut Reader<'_>, expected: u8) -> Result<(), &'static str> {
    let value = reader.expect(0x02)?.content;
    if value != [expected] {
        return Err("CMS_VERSION");
    }
    Ok(())
}

fn collect_octet_strings(
    input: &[u8],
    output: &mut Vec<u8>,
    depth: usize,
) -> Result<(), &'static str> {
    if depth >= MAX_ASN1_DEPTH {
        return Err("CMS_ASN1_DEPTH_OR_EOF");
    }
    let mut reader = Reader::new(input);
    while !reader.is_empty() {
        let value = reader.read()?;
        match value.tag {
            0x04 | 0x80 => output.extend_from_slice(value.content),
            0x24 | 0xa0 => collect_octet_strings(value.content, output, depth + 1)?,
            _ => return Err("CMS_ENCRYPTED_CONTENT_TAG"),
        }
        if output.len() > MAX_CMS_BYTES {
            return Err("CMS_ENCRYPTED_CONTENT_TOO_LARGE");
        }
    }
    Ok(())
}

fn expect_sha256_algorithm_identifier(input: &[u8]) -> Result<(), &'static str> {
    let mut algorithm = Reader::new(input);
    expect_oid(&mut algorithm, OID_SHA256)?;
    if !algorithm.expect(0x05)?.content.is_empty() || !algorithm.is_empty() {
        return Err("CMS_OAEP_SHA256_PARAMETERS");
    }
    Ok(())
}

fn expect_oaep_sha256_parameters(reader: &mut Reader<'_>) -> Result<(), &'static str> {
    let parameters = reader.expect(0x30)?;
    if !reader.is_empty() {
        return Err("CMS_OAEP_ALGORITHM_TRAILING");
    }
    let mut parameters_reader = Reader::new(parameters.content);

    let hash_context = parameters_reader.expect(0xa0)?;
    let mut hash_context_reader = Reader::new(hash_context.content);
    let hash_algorithm = hash_context_reader.expect(0x30)?;
    if !hash_context_reader.is_empty() {
        return Err("CMS_OAEP_HASH_TRAILING");
    }
    expect_sha256_algorithm_identifier(hash_algorithm.content)?;

    let mgf_context = parameters_reader.expect(0xa1)?;
    let mut mgf_context_reader = Reader::new(mgf_context.content);
    let mgf_algorithm = mgf_context_reader.expect(0x30)?;
    if !mgf_context_reader.is_empty() {
        return Err("CMS_OAEP_MGF_TRAILING");
    }
    let mut mgf_algorithm_reader = Reader::new(mgf_algorithm.content);
    expect_oid(&mut mgf_algorithm_reader, OID_MGF1)?;
    let mgf_hash_algorithm = mgf_algorithm_reader.expect(0x30)?;
    if !mgf_algorithm_reader.is_empty() {
        return Err("CMS_OAEP_MGF_PARAMETERS_TRAILING");
    }
    expect_sha256_algorithm_identifier(mgf_hash_algorithm.content)?;

    if parameters_reader.peek_tag() == Some(0xa2) {
        let source_context = parameters_reader.expect(0xa2)?;
        let mut source_context_reader = Reader::new(source_context.content);
        let source_algorithm = source_context_reader.expect(0x30)?;
        if !source_context_reader.is_empty() {
            return Err("CMS_OAEP_SOURCE_TRAILING");
        }
        let mut source_algorithm_reader = Reader::new(source_algorithm.content);
        expect_oid(&mut source_algorithm_reader, OID_PSPECIFIED)?;
        if !source_algorithm_reader.expect(0x04)?.content.is_empty()
            || !source_algorithm_reader.is_empty()
        {
            return Err("CMS_OAEP_NONEMPTY_LABEL");
        }
    }
    if !parameters_reader.is_empty() {
        return Err("CMS_OAEP_PARAMETERS_TRAILING");
    }
    Ok(())
}

pub fn parse_kms_recipient_cms(input: &[u8]) -> Result<KmsRecipientEnvelope, &'static str> {
    if input.is_empty() || input.len() > MAX_CMS_BYTES {
        return Err("CMS_SIZE");
    }

    let mut root = Reader::new(input);
    let outer = root.expect(0x30)?;
    if !root.is_empty() {
        return Err("CMS_TRAILING_DATA");
    }
    let mut content_info = Reader::new(outer.content);
    expect_oid(&mut content_info, OID_PKCS7_ENVELOPED_DATA)?;
    let explicit = content_info.expect(0xa0)?;
    if !content_info.is_empty() {
        return Err("CMS_CONTENT_INFO_TRAILING");
    }

    let mut explicit_reader = Reader::new(explicit.content);
    let enveloped = explicit_reader.expect(0x30)?;
    if !explicit_reader.is_empty() {
        return Err("CMS_EXPLICIT_TRAILING");
    }
    let mut enveloped_reader = Reader::new(enveloped.content);
    expect_version(&mut enveloped_reader, 2)?;
    if enveloped_reader.peek_tag() == Some(0xa0) {
        enveloped_reader.read()?;
    }

    let recipient_set = enveloped_reader.expect(0x31)?;
    let mut recipient_set_reader = Reader::new(recipient_set.content);
    let recipient = recipient_set_reader.expect(0x30)?;
    if !recipient_set_reader.is_empty() {
        return Err("CMS_MULTIPLE_RECIPIENTS");
    }
    let mut recipient_reader = Reader::new(recipient.content);
    expect_version(&mut recipient_reader, 2)?;
    recipient_reader.read()?;
    let key_algorithm = recipient_reader.expect(0x30)?;
    let mut key_algorithm_reader = Reader::new(key_algorithm.content);
    expect_oid(&mut key_algorithm_reader, OID_RSAES_OAEP)?;
    expect_oaep_sha256_parameters(&mut key_algorithm_reader)?;
    let encrypted_key = recipient_reader.expect(0x04)?.content.to_vec();
    if encrypted_key.len() != 256 || !recipient_reader.is_empty() {
        return Err("CMS_ENCRYPTED_KEY_LENGTH");
    }

    let encrypted_content_info = enveloped_reader.expect(0x30)?;
    if !enveloped_reader.is_empty() {
        return Err("CMS_ENVELOPED_TRAILING");
    }
    let mut encrypted_content_reader = Reader::new(encrypted_content_info.content);
    expect_oid(&mut encrypted_content_reader, OID_PKCS7_DATA)?;
    let content_algorithm = encrypted_content_reader.expect(0x30)?;
    let mut content_algorithm_reader = Reader::new(content_algorithm.content);
    expect_oid(&mut content_algorithm_reader, OID_AES_256_CBC)?;
    let iv = content_algorithm_reader.expect(0x04)?.content.to_vec();
    if iv.len() != 16 || !content_algorithm_reader.is_empty() {
        return Err("CMS_IV_LENGTH");
    }

    let mut ciphertext = Vec::new();
    while !encrypted_content_reader.is_empty() {
        let value = encrypted_content_reader.read()?;
        match value.tag {
            0x80 => ciphertext.extend_from_slice(value.content),
            0xa0 => collect_octet_strings(value.content, &mut ciphertext, 0)?,
            _ => return Err("CMS_ENCRYPTED_CONTENT_TAG"),
        }
    }
    if ciphertext.is_empty() || ciphertext.len() % 16 != 0 || ciphertext.len() > MAX_CMS_BYTES {
        return Err("CMS_CIPHERTEXT_LENGTH");
    }

    Ok(KmsRecipientEnvelope {
        encrypted_key,
        iv,
        ciphertext,
    })
}
