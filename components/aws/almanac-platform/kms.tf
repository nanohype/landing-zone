/**
 * KMS key for per-user OAuth token envelope encryption.
 *
 * Almanac's DDBKmsTokenStorage encrypts each user's token payload with a
 * data key wrapped by this CMK, binding the ciphertext to an
 * EncryptionContext of {userId, provider} so a leaked blob can't be
 * decrypted for a different pair. Rotation is annual.
 */

resource "aws_kms_key" "token_store" {
  description             = "${local.prefix} per-user OAuth token envelope encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "token_store" {
  name          = "alias/${local.prefix}-token-store"
  target_key_id = aws_kms_key.token_store.key_id
}
