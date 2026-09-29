-- CLRS staging structure for the EXISTING, empty MySQL 8.4 clrs_staging database.
-- No CREATE DATABASE, USE, GRANT, DROP, Firebase read/write, or user data.
-- MySQL DDL auto-commits. Apply once only after a schema review and backup.
-- All relational identifiers are byte-exact under utf8mb4_0900_bin and limited
-- to 191 characters; retain unsupported/long source IDs in legacy_* for review.
SET time_zone = '+00:00';

CREATE TABLE clrs_staging.accounts (
  uid VARCHAR(191) NOT NULL,
  email_normalized VARCHAR(320) NULL,
  email_verified TINYINT(1) NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1)),
  disabled TINYINT(1) NOT NULL DEFAULT 0 CHECK (disabled IN (0, 1)),
  lifecycle VARCHAR(20) NOT NULL DEFAULT 'active' CHECK (lifecycle IN ('active', 'blocked', 'deleted')),
  token_version BIGINT NOT NULL DEFAULT 0 CHECK (token_version >= 0),
  firebase_created_at DATETIME(6) NULL,
  firebase_last_login_at DATETIME(6) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  legacy_claims JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_claims) = 'OBJECT'),
  PRIMARY KEY (uid),
  UNIQUE KEY accounts_email_uq (email_normalized),
  CHECK (uid <> ''),
  CHECK (email_normalized IS NULL OR (email_normalized = LOWER(TRIM(email_normalized)) AND email_normalized <> ''))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.auth_identities (
  uid VARCHAR(191) NOT NULL,
  provider VARCHAR(191) NOT NULL CHECK (provider <> ''),
  provider_subject VARCHAR(191) NOT NULL CHECK (provider_subject <> ''),
  provider_email VARCHAR(320) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (provider, provider_subject),
  UNIQUE KEY auth_identities_uid_provider_uq (uid, provider, provider_subject),
  KEY auth_identities_uid_idx (uid),
  CONSTRAINT auth_identities_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- Password material and token ciphertext require a restricted service role.
CREATE TABLE clrs_staging.auth_credentials (
  uid VARCHAR(191) NOT NULL,
  scheme VARCHAR(30) NOT NULL CHECK (scheme IN ('firebase_scrypt', 'argon2id', 'bridge_only')),
  password_hash BLOB NULL,
  password_salt BLOB NULL,
  parameters JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(parameters) = 'OBJECT'),
  imported_at DATETIME(6) NULL,
  PRIMARY KEY (uid),
  CONSTRAINT auth_credentials_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CHECK ((scheme = 'bridge_only' AND password_hash IS NULL AND password_salt IS NULL)
      OR (scheme = 'firebase_scrypt' AND password_hash IS NOT NULL AND password_salt IS NOT NULL)
      OR (scheme = 'argon2id' AND password_hash IS NOT NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.device_sessions (
  session_id VARCHAR(191) NOT NULL CHECK (session_id <> ''),
  uid VARCHAR(191) NOT NULL,
  device_id VARCHAR(191) NOT NULL CHECK (device_id <> ''),
  refresh_token_hash VARBINARY(255) NOT NULL CHECK (OCTET_LENGTH(refresh_token_hash) >= 32),
  rotated_from VARCHAR(191) NULL,
  issued_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  expires_at DATETIME(6) NOT NULL,
  revoked_at DATETIME(6) NULL,
  last_used_at DATETIME(6) NULL,
  PRIMARY KEY (session_id),
  KEY device_sessions_live_uid_idx (uid, device_id, revoked_at, expires_at DESC),
  KEY device_sessions_rotated_idx (rotated_from),
  CONSTRAINT device_sessions_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT device_sessions_rotated_fk FOREIGN KEY (rotated_from) REFERENCES clrs_staging.device_sessions(session_id) ON DELETE SET NULL,
  CHECK (expires_at > issued_at)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.device_push_tokens (
  uid VARCHAR(191) NOT NULL,
  device_id VARCHAR(191) NOT NULL CHECK (device_id <> ''),
  fcm_token_hash VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(fcm_token_hash) = 32),
  fcm_token_ciphertext BLOB NOT NULL,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (uid, device_id),
  UNIQUE KEY device_push_tokens_hash_uq (fcm_token_hash),
  CONSTRAINT device_push_tokens_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.role_grants (
  uid VARCHAR(191) NOT NULL,
  role VARCHAR(30) NOT NULL CHECK (role IN ('admin', 'moderator', 'author')),
  verified_source VARCHAR(30) NOT NULL CHECK (verified_source IN ('firebase_claim', 'approved_uid', 'admin_grant')),
  granted_by VARCHAR(191) NULL,
  granted_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  revoked_at DATETIME(6) NULL,
  PRIMARY KEY (uid, role),
  KEY role_grants_granted_by_idx (granted_by),
  CONSTRAINT role_grants_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT role_grants_grantor_fk FOREIGN KEY (granted_by) REFERENCES clrs_staging.accounts(uid),
  CHECK (verified_source <> 'admin_grant' OR granted_by IS NOT NULL)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.profiles (
  uid VARCHAR(191) NOT NULL,
  full_name TEXT NULL,
  age INT NULL CHECK (age IS NULL OR age BETWEEN 0 AND 130),
  height_cm INT NULL CHECK (height_cm IS NULL OR height_cm BETWEEN 0 AND 300),
  about_text LONGTEXT NULL,
  interests_text LONGTEXT NULL,
  has_children TINYINT(1) NULL CHECK (has_children IS NULL OR has_children IN (0, 1)),
  gender VARCHAR(191) NULL,
  relationship_status VARCHAR(191) NULL,
  country VARCHAR(191) NULL,
  country_code VARCHAR(191) NULL,
  region VARCHAR(191) NULL,
  city VARCHAR(191) NULL,
  language_code VARCHAR(191) NULL,
  primary_group VARCHAR(191) NULL,
  secondary_group VARCHAR(191) NULL,
  test_result JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(test_result) = 'OBJECT'),
  profile_details_saved TINYINT(1) NOT NULL DEFAULT 0 CHECK (profile_details_saved IN (0, 1)),
  registration_complete TINYINT(1) NOT NULL DEFAULT 0 CHECK (registration_complete IN (0, 1)),
  invisible_until DATETIME(6) NULL,
  last_online_at DATETIME(6) NULL,
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (uid),
  KEY profiles_location_idx (country_code, region, uid),
  KEY profiles_group_idx (primary_group, uid),
  CONSTRAINT profiles_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- S3 object keys remain complete TEXT; SHA-256 columns index their full value.
-- The importer must compare the original string before accepting a hash match.
CREATE TABLE clrs_staging.media_objects (
  media_id VARCHAR(191) NOT NULL CHECK (media_id <> ''),
  owner_uid VARCHAR(191) NOT NULL,
  purpose VARCHAR(20) NOT NULL CHECK (purpose IN ('profile', 'post', 'comment', 'meeting', 'message', 'gift', 'other')),
  object_key TEXT NOT NULL CHECK (object_key <> ''),
  object_key_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(object_key, 256))) STORED,
  thumbnail_key TEXT NULL,
  thumbnail_key_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(thumbnail_key, 256))) STORED,
  mime_type VARCHAR(191) NOT NULL,
  byte_size BIGINT NULL CHECK (byte_size IS NULL OR byte_size >= 0),
  thumbnail_byte_size BIGINT NULL CHECK (thumbnail_byte_size IS NULL OR thumbnail_byte_size >= 0),
  sha256 VARBINARY(32) NULL CHECK (sha256 IS NULL OR OCTET_LENGTH(sha256) = 32),
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready', 'deleted')),
  legacy_storage_path TEXT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (media_id),
  UNIQUE KEY media_objects_owner_uq (media_id, owner_uid),
  UNIQUE KEY media_objects_object_key_uq (object_key_sha256),
  UNIQUE KEY media_objects_thumbnail_key_uq (thumbnail_key_sha256),
  KEY media_owner_purpose_idx (owner_uid, purpose, created_at DESC),
  CONSTRAINT media_objects_owner_fk FOREIGN KEY (owner_uid) REFERENCES clrs_staging.accounts(uid),
  CHECK (thumbnail_key IS NULL OR thumbnail_key <> object_key)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.profile_photos (
  uid VARCHAR(191) NOT NULL,
  media_id VARCHAR(191) NOT NULL,
  ordinal INT NOT NULL CHECK (ordinal >= 0),
  is_primary TINYINT(1) NOT NULL DEFAULT 0 CHECK (is_primary IN (0, 1)),
  primary_slot TINYINT GENERATED ALWAYS AS (CASE WHEN is_primary = 1 THEN 1 ELSE NULL END) STORED,
  firebase_image_id VARCHAR(191) NULL,
  PRIMARY KEY (uid, media_id),
  UNIQUE KEY profile_photos_ordinal_uq (uid, ordinal),
  UNIQUE KEY profile_one_primary_photo_uq (uid, primary_slot),
  KEY profile_photos_media_owner_idx (media_id, uid),
  CONSTRAINT profile_photos_profile_fk FOREIGN KEY (uid) REFERENCES clrs_staging.profiles(uid),
  CONSTRAINT profile_photos_media_owner_fk FOREIGN KEY (media_id, uid) REFERENCES clrs_staging.media_objects(media_id, owner_uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.chats (
  chat_id VARCHAR(191) NOT NULL CHECK (chat_id <> ''),
  uid_low VARCHAR(191) NOT NULL,
  uid_high VARCHAR(191) NOT NULL,
  created_at DATETIME(6) NULL,
  updated_at DATETIME(6) NULL,
  last_sequence BIGINT NOT NULL DEFAULT 0 CHECK (last_sequence >= 0),
  revision BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (chat_id),
  UNIQUE KEY chats_pair_uq (uid_low, uid_high),
  KEY chats_high_idx (uid_high, updated_at DESC, chat_id),
  KEY chats_low_idx (uid_low, updated_at DESC, chat_id),
  CONSTRAINT chats_low_fk FOREIGN KEY (uid_low) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT chats_high_fk FOREIGN KEY (uid_high) REFERENCES clrs_staging.accounts(uid),
  CHECK (uid_low < uid_high)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.chat_members (
  chat_id VARCHAR(191) NOT NULL,
  uid VARCHAR(191) NOT NULL,
  read_through_sequence BIGINT NOT NULL DEFAULT 0 CHECK (read_through_sequence >= 0),
  notifications_enabled TINYINT(1) NOT NULL DEFAULT 1 CHECK (notifications_enabled IN (0, 1)),
  archived_at DATETIME(6) NULL,
  PRIMARY KEY (chat_id, uid),
  KEY chat_members_account_idx (uid),
  CONSTRAINT chat_members_chat_fk FOREIGN KEY (chat_id) REFERENCES clrs_staging.chats(chat_id),
  CONSTRAINT chat_members_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- MySQL FKs are immediate: insert parent replies and chat members first.
CREATE TABLE clrs_staging.chat_messages (
  chat_id VARCHAR(191) NOT NULL,
  message_id VARCHAR(191) NOT NULL CHECK (message_id <> ''),
  sequence BIGINT NOT NULL CHECK (sequence > 0),
  sender_uid VARCHAR(191) NOT NULL,
  body LONGTEXT NULL,
  media_id VARCHAR(191) NULL,
  reply_to_id VARCHAR(191) NULL,
  gift_notice_id VARCHAR(191) NULL,
  created_at DATETIME(6) NULL,
  edited_at DATETIME(6) NULL,
  deleted_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (chat_id, message_id),
  UNIQUE KEY chat_messages_sequence_uq (chat_id, sequence),
  KEY chat_messages_page_idx (chat_id, sequence DESC),
  KEY chat_messages_sender_idx (chat_id, sender_uid),
  KEY chat_messages_reply_idx (chat_id, reply_to_id),
  KEY chat_messages_media_idx (media_id),
  CONSTRAINT chat_messages_chat_fk FOREIGN KEY (chat_id) REFERENCES clrs_staging.chats(chat_id),
  CONSTRAINT chat_messages_sender_fk FOREIGN KEY (sender_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT chat_messages_media_fk FOREIGN KEY (media_id) REFERENCES clrs_staging.media_objects(media_id),
  CONSTRAINT chat_messages_member_fk FOREIGN KEY (chat_id, sender_uid) REFERENCES clrs_staging.chat_members(chat_id, uid),
  CONSTRAINT chat_messages_reply_fk FOREIGN KEY (chat_id, reply_to_id) REFERENCES clrs_staging.chat_messages(chat_id, message_id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.meetings (
  meeting_id VARCHAR(191) NOT NULL CHECK (meeting_id <> ''),
  organizer_uid VARCHAR(191) NOT NULL,
  invited_uid VARCHAR(191) NULL,
  kind VARCHAR(20) NOT NULL CHECK (kind IN ('group', 'individual')),
  title TEXT NULL,
  description LONGTEXT NULL,
  country_code VARCHAR(191) NULL,
  region VARCHAR(191) NULL,
  starts_at DATETIME(6) NULL,
  created_at DATETIME(6) NULL,
  updated_at DATETIME(6) NULL,
  media_id VARCHAR(191) NULL,
  creation_request_id VARCHAR(191) NULL,
  revision BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
  deleted_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (meeting_id),
  UNIQUE KEY meetings_creation_request_uq (organizer_uid, creation_request_id),
  KEY meetings_browse_idx (kind, deleted_at, starts_at, meeting_id),
  KEY meetings_invited_idx (invited_uid, kind, deleted_at, starts_at, meeting_id),
  KEY meetings_media_idx (media_id),
  CONSTRAINT meetings_organizer_fk FOREIGN KEY (organizer_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT meetings_invited_fk FOREIGN KEY (invited_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT meetings_media_fk FOREIGN KEY (media_id) REFERENCES clrs_staging.media_objects(media_id),
  CHECK ((kind = 'individual' AND invited_uid IS NOT NULL AND invited_uid <> organizer_uid)
      OR (kind = 'group' AND invited_uid IS NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.meeting_members (
  meeting_id VARCHAR(191) NOT NULL,
  uid VARCHAR(191) NOT NULL,
  joined_at DATETIME(6) NULL,
  left_at DATETIME(6) NULL,
  kicked_at DATETIME(6) NULL,
  membership_revision BIGINT NOT NULL DEFAULT 0 CHECK (membership_revision >= 0),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (meeting_id, uid),
  KEY meeting_members_active_idx (meeting_id, left_at, uid),
  KEY meeting_members_account_idx (uid),
  CONSTRAINT meeting_members_meeting_fk FOREIGN KEY (meeting_id) REFERENCES clrs_staging.meetings(meeting_id),
  CONSTRAINT meeting_members_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CHECK (kicked_at IS NULL OR left_at IS NOT NULL)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.meeting_messages (
  meeting_id VARCHAR(191) NOT NULL,
  message_id VARCHAR(191) NOT NULL CHECK (message_id <> ''),
  sequence BIGINT NOT NULL CHECK (sequence > 0),
  sender_uid VARCHAR(191) NOT NULL,
  body LONGTEXT NULL,
  media_id VARCHAR(191) NULL,
  created_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (meeting_id, message_id),
  UNIQUE KEY meeting_messages_sequence_uq (meeting_id, sequence),
  KEY meeting_messages_page_idx (meeting_id, sequence DESC),
  KEY meeting_messages_sender_idx (meeting_id, sender_uid),
  KEY meeting_messages_media_idx (media_id),
  CONSTRAINT meeting_messages_meeting_fk FOREIGN KEY (meeting_id) REFERENCES clrs_staging.meetings(meeting_id),
  CONSTRAINT meeting_messages_sender_fk FOREIGN KEY (sender_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT meeting_messages_media_fk FOREIGN KEY (media_id) REFERENCES clrs_staging.media_objects(media_id),
  CONSTRAINT meeting_messages_member_fk FOREIGN KEY (meeting_id, sender_uid) REFERENCES clrs_staging.meeting_members(meeting_id, uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.removed_meeting_messages (
  owner_uid VARCHAR(191) NOT NULL,
  meeting_id VARCHAR(191) NOT NULL,
  message_id VARCHAR(191) NOT NULL CHECK (message_id <> ''),
  source_sequence BIGINT NULL,
  archived_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (owner_uid, meeting_id, message_id),
  KEY removed_meeting_messages_meeting_idx (meeting_id),
  CONSTRAINT removed_meeting_messages_owner_fk FOREIGN KEY (owner_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT removed_meeting_messages_meeting_fk FOREIGN KEY (meeting_id) REFERENCES clrs_staging.meetings(meeting_id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.friend_requests (
  requester_uid VARCHAR(191) NOT NULL,
  recipient_uid VARCHAR(191) NOT NULL,
  status VARCHAR(20) NOT NULL CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
  requested_at DATETIME(6) NULL,
  decided_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (requester_uid, recipient_uid),
  KEY friend_requests_incoming_idx (recipient_uid, status, requested_at DESC),
  KEY friend_requests_outgoing_idx (requester_uid, status, requested_at DESC),
  CONSTRAINT friend_requests_requester_fk FOREIGN KEY (requester_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT friend_requests_recipient_fk FOREIGN KEY (recipient_uid) REFERENCES clrs_staging.accounts(uid),
  CHECK (requester_uid <> recipient_uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.friendships (
  uid_low VARCHAR(191) NOT NULL,
  uid_high VARCHAR(191) NOT NULL,
  accepted_at DATETIME(6) NULL,
  PRIMARY KEY (uid_low, uid_high),
  KEY friendships_high_idx (uid_high, uid_low),
  CONSTRAINT friendships_low_fk FOREIGN KEY (uid_low) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT friendships_high_fk FOREIGN KEY (uid_high) REFERENCES clrs_staging.accounts(uid),
  CHECK (uid_low < uid_high)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.notifications (
  uid VARCHAR(191) NOT NULL,
  notification_id VARCHAR(191) NOT NULL CHECK (notification_id <> ''),
  source_event_id VARCHAR(191) NULL,
  kind VARCHAR(191) NOT NULL,
  actor_uid VARCHAR(191) NULL,
  entity_id VARCHAR(191) NULL,
  title_key VARCHAR(191) NULL,
  body_key VARCHAR(191) NULL,
  display_args JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(display_args) = 'OBJECT'),
  created_at DATETIME(6) NULL,
  read_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (uid, notification_id),
  UNIQUE KEY notification_source_once_uq (uid, source_event_id),
  KEY notifications_page_idx (uid, created_at DESC, notification_id),
  KEY notifications_actor_idx (actor_uid),
  CONSTRAINT notifications_owner_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT notifications_actor_fk FOREIGN KEY (actor_uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.gift_catalog (
  gift_id VARCHAR(191) NOT NULL CHECK (gift_id <> ''),
  asset_path VARCHAR(512) NOT NULL,
  name_key VARCHAR(191) NOT NULL,
  price_ag BIGINT NULL CHECK (price_ag IS NULL OR price_ag >= 0),
  active TINYINT(1) NOT NULL DEFAULT 1 CHECK (active IN (0, 1)),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (gift_id),
  UNIQUE KEY gift_catalog_asset_path_uq (asset_path)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.wallets (
  uid VARCHAR(191) NOT NULL,
  balance_ag BIGINT NOT NULL DEFAULT 0 CHECK (balance_ag >= 0),
  revision BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (uid),
  CONSTRAINT wallets_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.wallet_ledger (
  entry_id VARCHAR(191) NOT NULL CHECK (entry_id <> ''),
  uid VARCHAR(191) NOT NULL,
  delta_ag BIGINT NOT NULL CHECK (delta_ag <> 0),
  balance_after_ag BIGINT NOT NULL CHECK (balance_after_ag >= 0),
  reason VARCHAR(191) NOT NULL,
  source_kind VARCHAR(191) NULL,
  source_id VARCHAR(191) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (entry_id),
  UNIQUE KEY wallet_ledger_source_once_uq (uid, source_kind, source_id),
  KEY wallet_ledger_page_idx (uid, created_at DESC, entry_id),
  CONSTRAINT wallet_ledger_wallet_fk FOREIGN KEY (uid) REFERENCES clrs_staging.wallets(uid),
  CHECK ((source_kind IS NULL) = (source_id IS NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- Data model only: payment processing and Robokassa code remain unchanged.
CREATE TABLE clrs_staging.payment_receipts (
  provider VARCHAR(191) NOT NULL CHECK (provider <> ''),
  external_transaction_id VARCHAR(191) NOT NULL CHECK (external_transaction_id <> ''),
  uid VARCHAR(191) NOT NULL,
  amount_minor BIGINT NOT NULL CHECK (amount_minor >= 0),
  credited_ag BIGINT NULL CHECK (credited_ag IS NULL OR credited_ag >= 0),
  status VARCHAR(20) NOT NULL CHECK (status IN ('pending', 'confirmed', 'failed', 'refunded')),
  verified_at DATETIME(6) NULL,
  raw_callback JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(raw_callback) = 'OBJECT'),
  PRIMARY KEY (provider, external_transaction_id),
  KEY payment_receipts_account_idx (uid),
  CONSTRAINT payment_receipts_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.gift_inventory (
  uid VARCHAR(191) NOT NULL,
  gift_id VARCHAR(191) NOT NULL,
  owned_quantity BIGINT NOT NULL DEFAULT 0 CHECK (owned_quantity >= 0),
  received_quantity BIGINT NOT NULL DEFAULT 0 CHECK (received_quantity >= 0),
  PRIMARY KEY (uid, gift_id),
  KEY gift_inventory_gift_idx (gift_id),
  CONSTRAINT gift_inventory_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT gift_inventory_gift_fk FOREIGN KEY (gift_id) REFERENCES clrs_staging.gift_catalog(gift_id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.gift_transfers (
  transfer_id VARCHAR(191) NOT NULL CHECK (transfer_id <> ''),
  gift_id VARCHAR(191) NOT NULL,
  sender_uid VARCHAR(191) NOT NULL,
  recipient_uid VARCHAR(191) NOT NULL,
  chat_id VARCHAR(191) NULL,
  message_id VARCHAR(191) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (transfer_id),
  KEY gift_transfers_gift_idx (gift_id),
  KEY gift_transfers_sender_idx (sender_uid),
  KEY gift_transfers_recipient_idx (recipient_uid, created_at DESC),
  KEY gift_transfers_chat_message_idx (chat_id, message_id),
  CONSTRAINT gift_transfers_gift_fk FOREIGN KEY (gift_id) REFERENCES clrs_staging.gift_catalog(gift_id),
  CONSTRAINT gift_transfers_sender_fk FOREIGN KEY (sender_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT gift_transfers_recipient_fk FOREIGN KEY (recipient_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT gift_transfers_chat_fk FOREIGN KEY (chat_id) REFERENCES clrs_staging.chats(chat_id),
  CONSTRAINT gift_transfers_message_fk FOREIGN KEY (chat_id, message_id) REFERENCES clrs_staging.chat_messages(chat_id, message_id),
  CHECK (sender_uid <> recipient_uid),
  CHECK ((chat_id IS NULL) = (message_id IS NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.posts (
  post_id VARCHAR(191) NOT NULL CHECK (post_id <> ''),
  author_uid VARCHAR(191) NOT NULL,
  body LONGTEXT NULL,
  media_id VARCHAR(191) NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'published' CHECK (status IN ('draft', 'pending', 'published', 'hidden', 'deleted')),
  created_at DATETIME(6) NULL,
  updated_at DATETIME(6) NULL,
  like_count BIGINT NOT NULL DEFAULT 0 CHECK (like_count >= 0),
  comment_count BIGINT NOT NULL DEFAULT 0 CHECK (comment_count >= 0),
  share_count BIGINT NOT NULL DEFAULT 0 CHECK (share_count >= 0),
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (post_id),
  KEY posts_feed_idx (status, created_at DESC, post_id),
  KEY posts_author_idx (author_uid),
  KEY posts_media_idx (media_id),
  CONSTRAINT posts_author_fk FOREIGN KEY (author_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT posts_media_fk FOREIGN KEY (media_id) REFERENCES clrs_staging.media_objects(media_id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.post_comments (
  post_id VARCHAR(191) NOT NULL,
  comment_id VARCHAR(191) NOT NULL CHECK (comment_id <> ''),
  author_uid VARCHAR(191) NOT NULL,
  parent_id VARCHAR(191) NULL,
  body LONGTEXT NULL,
  media_id VARCHAR(191) NULL,
  created_at DATETIME(6) NULL,
  deleted_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (post_id, comment_id),
  KEY post_comments_page_idx (post_id, created_at, comment_id),
  KEY post_comments_parent_idx (post_id, parent_id),
  KEY post_comments_author_idx (author_uid),
  KEY post_comments_media_idx (media_id),
  CONSTRAINT post_comments_post_fk FOREIGN KEY (post_id) REFERENCES clrs_staging.posts(post_id),
  CONSTRAINT post_comments_author_fk FOREIGN KEY (author_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT post_comments_media_fk FOREIGN KEY (media_id) REFERENCES clrs_staging.media_objects(media_id),
  CONSTRAINT post_comments_parent_fk FOREIGN KEY (post_id, parent_id) REFERENCES clrs_staging.post_comments(post_id, comment_id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.post_likes (
  post_id VARCHAR(191) NOT NULL,
  uid VARCHAR(191) NOT NULL,
  created_at DATETIME(6) NULL,
  PRIMARY KEY (post_id, uid),
  KEY post_likes_account_idx (uid),
  CONSTRAINT post_likes_post_fk FOREIGN KEY (post_id) REFERENCES clrs_staging.posts(post_id),
  CONSTRAINT post_likes_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.comment_likes (
  post_id VARCHAR(191) NOT NULL,
  comment_id VARCHAR(191) NOT NULL,
  uid VARCHAR(191) NOT NULL,
  created_at DATETIME(6) NULL,
  PRIMARY KEY (post_id, comment_id, uid),
  KEY comment_likes_account_idx (uid),
  CONSTRAINT comment_likes_comment_fk FOREIGN KEY (post_id, comment_id) REFERENCES clrs_staging.post_comments(post_id, comment_id),
  CONSTRAINT comment_likes_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.wall_entries (
  uid VARCHAR(191) NOT NULL,
  post_id VARCHAR(191) NOT NULL,
  added_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (uid, post_id),
  KEY wall_entries_post_idx (post_id),
  CONSTRAINT wall_entries_account_fk FOREIGN KEY (uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT wall_entries_post_fk FOREIGN KEY (post_id) REFERENCES clrs_staging.posts(post_id)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.moderation_reports (
  report_id VARCHAR(191) NOT NULL CHECK (report_id <> ''),
  reporter_uid VARCHAR(191) NOT NULL,
  entity_kind VARCHAR(191) NOT NULL,
  entity_id VARCHAR(191) NOT NULL,
  status VARCHAR(20) NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'reviewing', 'resolved', 'dismissed')),
  created_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (report_id),
  KEY moderation_reports_queue_idx (status, created_at, report_id),
  KEY moderation_reports_reporter_idx (reporter_uid),
  CONSTRAINT moderation_reports_reporter_fk FOREIGN KEY (reporter_uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.role_requests (
  request_id VARCHAR(191) NOT NULL CHECK (request_id <> ''),
  requester_uid VARCHAR(191) NOT NULL,
  requested_role VARCHAR(30) NOT NULL CHECK (requested_role IN ('author', 'moderator')),
  status VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'declined')),
  reviewer_uid VARCHAR(191) NULL,
  created_at DATETIME(6) NULL,
  decided_at DATETIME(6) NULL,
  legacy_raw JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(legacy_raw) = 'OBJECT'),
  PRIMARY KEY (request_id),
  KEY role_requests_queue_idx (status, created_at, request_id),
  KEY role_requests_requester_idx (requester_uid),
  KEY role_requests_reviewer_idx (reviewer_uid),
  CONSTRAINT role_requests_requester_fk FOREIGN KEY (requester_uid) REFERENCES clrs_staging.accounts(uid),
  CONSTRAINT role_requests_reviewer_fk FOREIGN KEY (reviewer_uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.admin_audit (
  audit_id BIGINT NOT NULL AUTO_INCREMENT,
  actor_uid VARCHAR(191) NOT NULL,
  action VARCHAR(191) NOT NULL CHECK (action <> ''),
  target_kind VARCHAR(191) NOT NULL,
  target_id VARCHAR(191) NOT NULL,
  request_id VARCHAR(191) NULL,
  details JSON NOT NULL DEFAULT (JSON_OBJECT()) CHECK (JSON_TYPE(details) = 'OBJECT'),
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (audit_id),
  KEY admin_audit_target_idx (target_kind, target_id, audit_id DESC),
  KEY admin_audit_actor_idx (actor_uid),
  CONSTRAINT admin_audit_actor_fk FOREIGN KEY (actor_uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.idempotency_receipts (
  actor_uid VARCHAR(191) NOT NULL,
  operation VARCHAR(191) NOT NULL CHECK (operation <> ''),
  idempotency_key VARCHAR(191) NOT NULL CHECK (idempotency_key <> ''),
  request_hash VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(request_hash) = 32),
  state VARCHAR(20) NOT NULL CHECK (state IN ('processing', 'completed')),
  response_status INT NULL CHECK (response_status IS NULL OR response_status BETWEEN 200 AND 599),
  result JSON NULL,
  entity_revision BIGINT NULL CHECK (entity_revision IS NULL OR entity_revision >= 0),
  started_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  completed_at DATETIME(6) NULL,
  PRIMARY KEY (actor_uid, operation, idempotency_key),
  CONSTRAINT idempotency_receipts_actor_fk FOREIGN KEY (actor_uid) REFERENCES clrs_staging.accounts(uid),
  CHECK ((state = 'completed' AND response_status IS NOT NULL AND completed_at IS NOT NULL)
      OR (state = 'processing' AND completed_at IS NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- Serialize UPDATE event_counter SET last_id=last_id+1 with event insertion
-- inside one transaction. Do not use AUTO_INCREMENT for SSE commit order.
CREATE TABLE clrs_staging.event_counter (
  singleton TINYINT(1) NOT NULL DEFAULT 1 CHECK (singleton = 1),
  last_id BIGINT NOT NULL DEFAULT 0 CHECK (last_id >= 0),
  PRIMARY KEY (singleton)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
INSERT INTO clrs_staging.event_counter (singleton, last_id) VALUES (1, 0);

CREATE TABLE clrs_staging.user_events (
  event_id BIGINT NOT NULL CHECK (event_id > 0),
  audience_uid VARCHAR(191) NOT NULL,
  event_kind VARCHAR(191) NOT NULL,
  payload JSON NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (event_id),
  KEY user_events_audience_idx (audience_uid, event_id),
  CONSTRAINT user_events_audience_fk FOREIGN KEY (audience_uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.outbox (
  outbox_id VARCHAR(191) NOT NULL CHECK (outbox_id <> ''),
  source_event_id VARCHAR(191) NOT NULL,
  audience_uid VARCHAR(191) NOT NULL,
  channel VARCHAR(20) NOT NULL CHECK (channel IN ('fcm', 'email', 'webhook')),
  event_kind VARCHAR(191) NOT NULL,
  payload JSON NOT NULL,
  available_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  attempts INT NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  delivered_at DATETIME(6) NULL,
  last_error_code VARCHAR(191) NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (outbox_id),
  UNIQUE KEY outbox_delivery_once_uq (channel, audience_uid, source_event_id),
  KEY outbox_ready_idx (delivered_at, available_at, outbox_id),
  KEY outbox_audience_idx (audience_uid),
  CONSTRAINT outbox_audience_fk FOREIGN KEY (audience_uid) REFERENCES clrs_staging.accounts(uid)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- Source archive keeps complete Firestore paths, values, timestamps and S3
-- metadata. It deliberately has no parent FK: orphaned subcollections survive.
CREATE TABLE clrs_staging.legacy_source (
  singleton TINYINT(1) NOT NULL DEFAULT 1 CHECK (singleton = 1),
  source_project VARCHAR(191) NOT NULL CHECK (source_project <> ''),
  source_database VARCHAR(191) NOT NULL CHECK (source_database <> ''),
  source_bucket VARCHAR(191) NOT NULL CHECK (source_bucket <> ''),
  first_imported_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (singleton)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- SHA-256 indexes are for lookup/uniqueness, not a replacement for full path
-- comparison by the future importer/verifier. No path is truncated on ingest.
CREATE TABLE clrs_staging.legacy_documents (
  archive_id BIGINT NOT NULL AUTO_INCREMENT,
  firebase_path LONGTEXT NOT NULL CHECK (firebase_path <> '' AND LEFT(firebase_path, 1) <> '/'),
  firebase_path_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(firebase_path, 256))) STORED,
  parent_path LONGTEXT NULL,
  parent_path_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(parent_path, 256))) STORED,
  collection_path LONGTEXT NOT NULL,
  collection_path_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(collection_path, 256))) STORED,
  document_id TEXT NOT NULL,
  document_id_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(document_id, 256))) STORED,
  encoded_payload JSON NOT NULL,
  payload_sha256 VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(payload_sha256) = 32),
  target_table VARCHAR(191) NULL,
  target_id VARCHAR(191) NULL,
  imported_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  promoted_at DATETIME(6) NULL,
  PRIMARY KEY (archive_id),
  UNIQUE KEY legacy_documents_path_uq (firebase_path_sha256),
  KEY legacy_documents_collection_idx (collection_path_sha256, document_id_sha256),
  KEY legacy_documents_parent_idx (parent_path_sha256),
  CHECK ((target_table IS NULL) = (target_id IS NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.legacy_storage_objects (
  archive_id BIGINT NOT NULL AUTO_INCREMENT,
  source_bucket VARCHAR(191) NOT NULL,
  source_path LONGTEXT NOT NULL,
  source_path_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(source_path, 256))) STORED,
  source_metadata JSON NOT NULL CHECK (JSON_TYPE(source_metadata) = 'OBJECT'),
  source_size BIGINT NOT NULL CHECK (source_size >= 0),
  source_sha256 VARBINARY(32) NULL CHECK (source_sha256 IS NULL OR OCTET_LENGTH(source_sha256) = 32),
  target_key TEXT NULL,
  target_key_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(target_key, 256))) STORED,
  target_sha256 VARBINARY(32) NULL CHECK (target_sha256 IS NULL OR OCTET_LENGTH(target_sha256) = 32),
  copied_at DATETIME(6) NULL,
  PRIMARY KEY (archive_id),
  UNIQUE KEY legacy_storage_source_uq (source_bucket, source_path_sha256),
  UNIQUE KEY legacy_storage_target_uq (target_key_sha256),
  CHECK (copied_at IS NULL OR (target_key IS NOT NULL AND target_sha256 IS NOT NULL))
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

CREATE TABLE clrs_staging.legacy_auth_users (
  archive_id BIGINT NOT NULL AUTO_INCREMENT,
  uid LONGTEXT NOT NULL CHECK (uid <> ''),
  uid_sha256 BINARY(32) GENERATED ALWAYS AS (UNHEX(SHA2(uid, 256))) STORED,
  encoded_payload JSON NOT NULL,
  payload_sha256 VARBINARY(32) NOT NULL CHECK (OCTET_LENGTH(payload_sha256) = 32),
  promoted_at DATETIME(6) NULL,
  PRIMARY KEY (archive_id),
  UNIQUE KEY legacy_auth_users_uid_uq (uid_sha256)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;

-- Last statement: if an earlier CREATE fails, version 1 is never recorded.
CREATE TABLE clrs_staging.schema_migrations (
  version INT NOT NULL,
  applied_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (version)
) ENGINE=InnoDB ROW_FORMAT=DYNAMIC DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin;
INSERT INTO clrs_staging.schema_migrations (version) VALUES (1);
