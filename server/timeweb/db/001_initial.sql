-- CLRS Timeweb staging schema. Run only in a NEW, isolated PostgreSQL database.
-- The importer first records every Firebase document/object in the legacy_* tables;
-- only validated records are promoted into the relational tables below.
BEGIN;
SELECT pg_advisory_xact_lock(hashtext('clrs:001_initial'));
CREATE SCHEMA clrs;
REVOKE ALL ON SCHEMA clrs FROM PUBLIC;

CREATE TABLE clrs.schema_migrations (
  version integer PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO clrs.schema_migrations(version) VALUES (1);

-- Firebase UIDs remain primary keys throughout the new backend.
CREATE TABLE clrs.accounts (
  uid text PRIMARY KEY CHECK (uid <> ''),
  email_normalized text UNIQUE,
  email_verified boolean NOT NULL DEFAULT false,
  disabled boolean NOT NULL DEFAULT false,
  lifecycle text NOT NULL DEFAULT 'active' CHECK (lifecycle IN ('active', 'blocked', 'deleted')),
  token_version bigint NOT NULL DEFAULT 0 CHECK (token_version >= 0),
  firebase_created_at timestamptz,
  firebase_last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  legacy_claims jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_claims) = 'object'),
  CHECK (email_normalized IS NULL OR (email_normalized = lower(btrim(email_normalized)) AND email_normalized <> ''))
);

CREATE TABLE clrs.auth_identities (
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  provider text NOT NULL CHECK (provider <> ''),
  provider_subject text NOT NULL CHECK (provider_subject <> ''),
  provider_email text,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (provider, provider_subject),
  UNIQUE (uid, provider, provider_subject)
);
CREATE INDEX auth_identities_uid_idx ON clrs.auth_identities(uid);

-- Imported Firebase Scrypt material is private to the auth service. An account
-- may instead use the temporary Firebase-ID-token bridge; do not synthesize a hash.
CREATE TABLE clrs.auth_credentials (
  uid text PRIMARY KEY REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  scheme text NOT NULL CHECK (scheme IN ('firebase_scrypt', 'argon2id', 'bridge_only')),
  password_hash bytea,
  password_salt bytea,
  parameters jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(parameters) = 'object'),
  imported_at timestamptz,
  CHECK ((scheme = 'bridge_only' AND password_hash IS NULL AND password_salt IS NULL)
      OR (scheme = 'firebase_scrypt' AND password_hash IS NOT NULL AND password_salt IS NOT NULL)
      OR (scheme = 'argon2id' AND password_hash IS NOT NULL))
);

CREATE TABLE clrs.device_sessions (
  session_id text PRIMARY KEY CHECK (session_id <> ''),
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  device_id text NOT NULL CHECK (device_id <> ''),
  refresh_token_hash bytea NOT NULL CHECK (length(refresh_token_hash) >= 32),
  rotated_from text REFERENCES clrs.device_sessions(session_id) ON DELETE SET NULL,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  last_used_at timestamptz,
  CHECK (expires_at > issued_at)
);
CREATE INDEX device_sessions_live_uid_idx ON clrs.device_sessions(uid, device_id, expires_at DESC) WHERE revoked_at IS NULL;

CREATE TABLE clrs.device_push_tokens (
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  device_id text NOT NULL CHECK (device_id <> ''),
  fcm_token_hash bytea NOT NULL CHECK (length(fcm_token_hash) = 32),
  fcm_token_ciphertext bytea NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (uid, device_id),
  UNIQUE (fcm_token_hash)
);

-- Roles are derived only from verified claims/approved owners, never profile JSON.
CREATE TABLE clrs.role_grants (
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  role text NOT NULL CHECK (role IN ('admin', 'moderator', 'author')),
  verified_source text NOT NULL CHECK (verified_source IN ('firebase_claim', 'approved_uid', 'admin_grant')),
  granted_by text REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  granted_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  PRIMARY KEY (uid, role),
  CHECK (verified_source <> 'admin_grant' OR granted_by IS NOT NULL)
);

CREATE TABLE clrs.profiles (
  uid text PRIMARY KEY REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  full_name text,
  age integer CHECK (age IS NULL OR age BETWEEN 0 AND 130),
  height_cm integer CHECK (height_cm IS NULL OR height_cm BETWEEN 0 AND 300),
  about_text text,
  interests_text text,
  has_children boolean,
  gender text,
  relationship_status text,
  country text,
  country_code text,
  region text,
  city text,
  language_code text,
  primary_group text,
  secondary_group text,
  test_result jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(test_result) = 'object'),
  profile_details_saved boolean NOT NULL DEFAULT false,
  registration_complete boolean NOT NULL DEFAULT false,
  invisible_until timestamptz,
  last_online_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now(),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object')
);
CREATE INDEX profiles_location_idx ON clrs.profiles(country_code, region, uid);
CREATE INDEX profiles_group_idx ON clrs.profiles(primary_group, uid);

-- Object keys point only to a private S3 bucket. Signed URLs are never stored.
CREATE TABLE clrs.media_objects (
  media_id text PRIMARY KEY CHECK (media_id <> ''),
  owner_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  purpose text NOT NULL CHECK (purpose IN ('profile', 'post', 'comment', 'meeting', 'message', 'gift', 'other')),
  object_key text NOT NULL UNIQUE CHECK (object_key <> ''),
  thumbnail_key text UNIQUE,
  mime_type text NOT NULL,
  byte_size bigint CHECK (byte_size IS NULL OR byte_size >= 0),
  thumbnail_byte_size bigint CHECK (thumbnail_byte_size IS NULL OR thumbnail_byte_size >= 0),
  sha256 bytea CHECK (sha256 IS NULL OR length(sha256) = 32),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'ready', 'deleted')),
  legacy_storage_path text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (media_id, owner_uid),
  CHECK (thumbnail_key IS NULL OR thumbnail_key <> object_key)
);
CREATE INDEX media_owner_purpose_idx ON clrs.media_objects(owner_uid, purpose, created_at DESC);

CREATE TABLE clrs.profile_photos (
  uid text NOT NULL REFERENCES clrs.profiles(uid) ON DELETE RESTRICT,
  media_id text NOT NULL,
  ordinal integer NOT NULL CHECK (ordinal >= 0),
  is_primary boolean NOT NULL DEFAULT false,
  firebase_image_id text,
  PRIMARY KEY (uid, media_id),
  UNIQUE (uid, ordinal),
  FOREIGN KEY (media_id, uid) REFERENCES clrs.media_objects(media_id, owner_uid) ON DELETE RESTRICT
);
CREATE UNIQUE INDEX profile_one_primary_photo_idx ON clrs.profile_photos(uid) WHERE is_primary;

CREATE TABLE clrs.chats (
  chat_id text PRIMARY KEY CHECK (chat_id <> ''),
  uid_low text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  uid_high text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  created_at timestamptz,
  updated_at timestamptz,
  last_sequence bigint NOT NULL DEFAULT 0 CHECK (last_sequence >= 0),
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  CHECK (uid_low < uid_high),
  UNIQUE (uid_low, uid_high)
);
CREATE INDEX chats_high_idx ON clrs.chats(uid_high, updated_at DESC, chat_id);
CREATE INDEX chats_low_idx ON clrs.chats(uid_low, updated_at DESC, chat_id);

CREATE TABLE clrs.chat_members (
  chat_id text NOT NULL REFERENCES clrs.chats(chat_id) ON DELETE RESTRICT,
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  read_through_sequence bigint NOT NULL DEFAULT 0 CHECK (read_through_sequence >= 0),
  notifications_enabled boolean NOT NULL DEFAULT true,
  archived_at timestamptz,
  PRIMARY KEY (chat_id, uid)
);

CREATE TABLE clrs.chat_messages (
  chat_id text NOT NULL REFERENCES clrs.chats(chat_id) ON DELETE RESTRICT,
  message_id text NOT NULL CHECK (message_id <> ''),
  sequence bigint NOT NULL CHECK (sequence > 0),
  sender_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  body text,
  media_id text REFERENCES clrs.media_objects(media_id) ON DELETE RESTRICT,
  reply_to_id text,
  gift_notice_id text,
  created_at timestamptz,
  edited_at timestamptz,
  deleted_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (chat_id, message_id),
  UNIQUE (chat_id, sequence),
  FOREIGN KEY (chat_id, sender_uid) REFERENCES clrs.chat_members(chat_id, uid) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (chat_id, reply_to_id) REFERENCES clrs.chat_messages(chat_id, message_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX chat_messages_page_idx ON clrs.chat_messages(chat_id, sequence DESC);

CREATE TABLE clrs.meetings (
  meeting_id text PRIMARY KEY CHECK (meeting_id <> ''),
  organizer_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  invited_uid text REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  kind text NOT NULL CHECK (kind IN ('group', 'individual')),
  title text,
  description text,
  country_code text,
  region text,
  starts_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  media_id text REFERENCES clrs.media_objects(media_id) ON DELETE RESTRICT,
  creation_request_id text,
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  deleted_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  CHECK ((kind = 'individual' AND invited_uid IS NOT NULL AND invited_uid <> organizer_uid) OR (kind = 'group' AND invited_uid IS NULL)),
  UNIQUE (organizer_uid, creation_request_id)
);
CREATE INDEX meetings_browse_idx ON clrs.meetings(starts_at, meeting_id) WHERE deleted_at IS NULL AND kind = 'group';
CREATE INDEX meetings_invited_idx ON clrs.meetings(invited_uid, starts_at, meeting_id) WHERE kind = 'individual' AND deleted_at IS NULL;

CREATE TABLE clrs.meeting_members (
  meeting_id text NOT NULL REFERENCES clrs.meetings(meeting_id) ON DELETE RESTRICT,
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  joined_at timestamptz,
  left_at timestamptz,
  kicked_at timestamptz,
  membership_revision bigint NOT NULL DEFAULT 0 CHECK (membership_revision >= 0),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (meeting_id, uid),
  CHECK (kicked_at IS NULL OR left_at IS NOT NULL)
);
CREATE INDEX meeting_members_active_idx ON clrs.meeting_members(meeting_id, uid) WHERE left_at IS NULL;

CREATE TABLE clrs.meeting_messages (
  meeting_id text NOT NULL REFERENCES clrs.meetings(meeting_id) ON DELETE RESTRICT,
  message_id text NOT NULL CHECK (message_id <> ''),
  sequence bigint NOT NULL CHECK (sequence > 0),
  sender_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  body text,
  media_id text REFERENCES clrs.media_objects(media_id) ON DELETE RESTRICT,
  created_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (meeting_id, message_id),
  UNIQUE (meeting_id, sequence),
  FOREIGN KEY (meeting_id, sender_uid) REFERENCES clrs.meeting_members(meeting_id, uid) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX meeting_messages_page_idx ON clrs.meeting_messages(meeting_id, sequence DESC);

CREATE TABLE clrs.removed_meeting_messages (
  owner_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  meeting_id text NOT NULL REFERENCES clrs.meetings(meeting_id) ON DELETE RESTRICT,
  message_id text NOT NULL CHECK (message_id <> ''),
  source_sequence bigint,
  archived_at timestamptz NOT NULL DEFAULT now(),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (owner_uid, meeting_id, message_id)
);

CREATE TABLE clrs.friend_requests (
  requester_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  recipient_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  status text NOT NULL CHECK (status IN ('pending', 'accepted', 'declined', 'cancelled')),
  requested_at timestamptz,
  decided_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (requester_uid, recipient_uid),
  CHECK (requester_uid <> recipient_uid)
);
CREATE INDEX friend_requests_incoming_idx ON clrs.friend_requests(recipient_uid, requested_at DESC) WHERE status = 'pending';
CREATE INDEX friend_requests_outgoing_idx ON clrs.friend_requests(requester_uid, requested_at DESC) WHERE status = 'pending';

CREATE TABLE clrs.friendships (
  uid_low text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  uid_high text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  accepted_at timestamptz,
  PRIMARY KEY (uid_low, uid_high),
  CHECK (uid_low < uid_high)
);
CREATE INDEX friendships_high_idx ON clrs.friendships(uid_high, uid_low);

CREATE TABLE clrs.notifications (
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  notification_id text NOT NULL CHECK (notification_id <> ''),
  source_event_id text,
  kind text NOT NULL,
  actor_uid text REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  entity_id text,
  title_key text,
  body_key text,
  display_args jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(display_args) = 'object'),
  created_at timestamptz,
  read_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (uid, notification_id)
);
CREATE UNIQUE INDEX notification_source_once_idx ON clrs.notifications(uid, source_event_id) WHERE source_event_id IS NOT NULL;
CREATE INDEX notifications_page_idx ON clrs.notifications(uid, created_at DESC, notification_id);

CREATE TABLE clrs.gift_catalog (
  gift_id text PRIMARY KEY CHECK (gift_id <> ''),
  asset_path text NOT NULL UNIQUE,
  name_key text NOT NULL,
  price_ag bigint CHECK (price_ag IS NULL OR price_ag >= 0),
  active boolean NOT NULL DEFAULT true,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object')
);

CREATE TABLE clrs.wallets (
  uid text PRIMARY KEY REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  balance_ag bigint NOT NULL DEFAULT 0 CHECK (balance_ag >= 0),
  revision bigint NOT NULL DEFAULT 0 CHECK (revision >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object')
);

CREATE TABLE clrs.wallet_ledger (
  entry_id text PRIMARY KEY CHECK (entry_id <> ''),
  uid text NOT NULL REFERENCES clrs.wallets(uid) ON DELETE RESTRICT,
  delta_ag bigint NOT NULL CHECK (delta_ag <> 0),
  balance_after_ag bigint NOT NULL CHECK (balance_after_ag >= 0),
  reason text NOT NULL,
  source_kind text,
  source_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  CHECK ((source_kind IS NULL) = (source_id IS NULL))
);
CREATE UNIQUE INDEX wallet_ledger_source_once_idx ON clrs.wallet_ledger(uid, source_kind, source_id) WHERE source_kind IS NOT NULL;
CREATE INDEX wallet_ledger_page_idx ON clrs.wallet_ledger(uid, created_at DESC, entry_id);

CREATE TABLE clrs.payment_receipts (
  provider text NOT NULL CHECK (provider <> ''),
  external_transaction_id text NOT NULL CHECK (external_transaction_id <> ''),
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  amount_minor bigint NOT NULL CHECK (amount_minor >= 0),
  credited_ag bigint CHECK (credited_ag IS NULL OR credited_ag >= 0),
  status text NOT NULL CHECK (status IN ('pending', 'confirmed', 'failed', 'refunded')),
  verified_at timestamptz,
  raw_callback jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(raw_callback) = 'object'),
  PRIMARY KEY (provider, external_transaction_id)
);

CREATE TABLE clrs.gift_inventory (
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  gift_id text NOT NULL REFERENCES clrs.gift_catalog(gift_id) ON DELETE RESTRICT,
  owned_quantity bigint NOT NULL DEFAULT 0 CHECK (owned_quantity >= 0),
  received_quantity bigint NOT NULL DEFAULT 0 CHECK (received_quantity >= 0),
  PRIMARY KEY (uid, gift_id)
);

CREATE TABLE clrs.gift_transfers (
  transfer_id text PRIMARY KEY CHECK (transfer_id <> ''),
  gift_id text NOT NULL REFERENCES clrs.gift_catalog(gift_id) ON DELETE RESTRICT,
  sender_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  recipient_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  chat_id text REFERENCES clrs.chats(chat_id) ON DELETE RESTRICT,
  message_id text,
  created_at timestamptz NOT NULL DEFAULT now(),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  CHECK (sender_uid <> recipient_uid),
  CHECK ((chat_id IS NULL) = (message_id IS NULL)),
  FOREIGN KEY (chat_id, message_id) REFERENCES clrs.chat_messages(chat_id, message_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX gift_transfers_recipient_idx ON clrs.gift_transfers(recipient_uid, created_at DESC);

CREATE TABLE clrs.posts (
  post_id text PRIMARY KEY CHECK (post_id <> ''),
  author_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  body text,
  media_id text REFERENCES clrs.media_objects(media_id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'published' CHECK (status IN ('draft', 'pending', 'published', 'hidden', 'deleted')),
  created_at timestamptz,
  updated_at timestamptz,
  like_count bigint NOT NULL DEFAULT 0 CHECK (like_count >= 0),
  comment_count bigint NOT NULL DEFAULT 0 CHECK (comment_count >= 0),
  share_count bigint NOT NULL DEFAULT 0 CHECK (share_count >= 0),
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object')
);
CREATE INDEX posts_feed_idx ON clrs.posts(created_at DESC, post_id) WHERE status = 'published';

CREATE TABLE clrs.post_comments (
  post_id text NOT NULL REFERENCES clrs.posts(post_id) ON DELETE RESTRICT,
  comment_id text NOT NULL CHECK (comment_id <> ''),
  author_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  parent_id text,
  body text,
  media_id text REFERENCES clrs.media_objects(media_id) ON DELETE RESTRICT,
  created_at timestamptz,
  deleted_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (post_id, comment_id),
  FOREIGN KEY (post_id, parent_id) REFERENCES clrs.post_comments(post_id, comment_id) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX post_comments_page_idx ON clrs.post_comments(post_id, created_at, comment_id);

CREATE TABLE clrs.post_likes (
  post_id text NOT NULL REFERENCES clrs.posts(post_id) ON DELETE RESTRICT,
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  created_at timestamptz,
  PRIMARY KEY (post_id, uid)
);
CREATE TABLE clrs.comment_likes (
  post_id text NOT NULL,
  comment_id text NOT NULL,
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  created_at timestamptz,
  PRIMARY KEY (post_id, comment_id, uid),
  FOREIGN KEY (post_id, comment_id) REFERENCES clrs.post_comments(post_id, comment_id) ON DELETE RESTRICT
);
CREATE TABLE clrs.wall_entries (
  uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  post_id text NOT NULL REFERENCES clrs.posts(post_id) ON DELETE RESTRICT,
  added_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object'),
  PRIMARY KEY (uid, post_id)
);

CREATE TABLE clrs.moderation_reports (
  report_id text PRIMARY KEY CHECK (report_id <> ''),
  reporter_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  entity_kind text NOT NULL,
  entity_id text NOT NULL,
  status text NOT NULL DEFAULT 'new' CHECK (status IN ('new', 'reviewing', 'resolved', 'dismissed')),
  created_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object')
);
CREATE INDEX moderation_reports_queue_idx ON clrs.moderation_reports(status, created_at, report_id);

CREATE TABLE clrs.role_requests (
  request_id text PRIMARY KEY CHECK (request_id <> ''),
  requester_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  requested_role text NOT NULL CHECK (requested_role IN ('author', 'moderator')),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'declined')),
  reviewer_uid text REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  created_at timestamptz,
  decided_at timestamptz,
  legacy_raw jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(legacy_raw) = 'object')
);
CREATE INDEX role_requests_queue_idx ON clrs.role_requests(status, created_at, request_id);

CREATE TABLE clrs.admin_audit (
  audit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  action text NOT NULL CHECK (action <> ''),
  target_kind text NOT NULL,
  target_id text NOT NULL,
  request_id text,
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX admin_audit_target_idx ON clrs.admin_audit(target_kind, target_id, audit_id DESC);

CREATE TABLE clrs.idempotency_receipts (
  actor_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  operation text NOT NULL CHECK (operation <> ''),
  idempotency_key text NOT NULL CHECK (idempotency_key <> ''),
  request_hash bytea NOT NULL CHECK (length(request_hash) = 32),
  state text NOT NULL CHECK (state IN ('processing', 'completed')),
  response_status integer CHECK (response_status IS NULL OR response_status BETWEEN 200 AND 599),
  result jsonb,
  entity_revision bigint CHECK (entity_revision IS NULL OR entity_revision >= 0),
  started_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  PRIMARY KEY (actor_uid, operation, idempotency_key),
  CHECK ((state = 'completed' AND response_status IS NOT NULL AND completed_at IS NOT NULL) OR (state = 'processing' AND completed_at IS NULL))
);

-- Locking this single counter row in the same transaction serializes event IDs
-- in commit order. The API increments it before inserting an event.
CREATE TABLE clrs.event_counter (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  last_id bigint NOT NULL DEFAULT 0 CHECK (last_id >= 0)
);
INSERT INTO clrs.event_counter(singleton, last_id) VALUES (true, 0);
CREATE TABLE clrs.user_events (
  event_id bigint PRIMARY KEY CHECK (event_id > 0),
  audience_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  event_kind text NOT NULL,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX user_events_audience_idx ON clrs.user_events(audience_uid, event_id);

CREATE TABLE clrs.outbox (
  outbox_id text PRIMARY KEY CHECK (outbox_id <> ''),
  source_event_id text NOT NULL,
  audience_uid text NOT NULL REFERENCES clrs.accounts(uid) ON DELETE RESTRICT,
  channel text NOT NULL CHECK (channel IN ('fcm', 'email', 'webhook')),
  event_kind text NOT NULL,
  payload jsonb NOT NULL,
  available_at timestamptz NOT NULL DEFAULT now(),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  delivered_at timestamptz,
  last_error_code text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX outbox_delivery_once_idx ON clrs.outbox(channel, audience_uid, source_event_id);
CREATE INDEX outbox_ready_idx ON clrs.outbox(available_at, outbox_id) WHERE delivered_at IS NULL;

-- Import receipts preserve every source path even when its parent is absent.
-- Payload must be Firebase type-tagged JSON, retaining timestamp/reference/etc.
CREATE TABLE clrs.legacy_source (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  source_project text NOT NULL CHECK (source_project <> ''),
  source_database text NOT NULL CHECK (source_database <> ''),
  source_bucket text NOT NULL CHECK (source_bucket <> ''),
  first_imported_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE clrs.legacy_documents (
  firebase_path text PRIMARY KEY CHECK (firebase_path <> '' AND left(firebase_path, 1) <> '/'),
  parent_path text,
  collection_path text NOT NULL,
  document_id text NOT NULL,
  encoded_payload jsonb NOT NULL,
  payload_sha256 bytea NOT NULL CHECK (length(payload_sha256) = 32),
  target_table text,
  target_id text,
  imported_at timestamptz NOT NULL DEFAULT now(),
  promoted_at timestamptz,
  CHECK ((target_table IS NULL) = (target_id IS NULL))
);
CREATE INDEX legacy_documents_collection_idx ON clrs.legacy_documents(collection_path, document_id);
CREATE INDEX legacy_documents_parent_idx ON clrs.legacy_documents(parent_path);

CREATE TABLE clrs.legacy_storage_objects (
  source_bucket text NOT NULL,
  source_path text NOT NULL,
  source_metadata jsonb NOT NULL CHECK (jsonb_typeof(source_metadata) = 'object'),
  source_size bigint NOT NULL CHECK (source_size >= 0),
  source_sha256 bytea,
  target_key text UNIQUE,
  target_sha256 bytea,
  copied_at timestamptz,
  PRIMARY KEY (source_bucket, source_path),
  CHECK (source_sha256 IS NULL OR length(source_sha256) = 32),
  CHECK (target_sha256 IS NULL OR length(target_sha256) = 32),
  CHECK (copied_at IS NULL OR (target_key IS NOT NULL AND target_sha256 IS NOT NULL))
);

CREATE TABLE clrs.legacy_auth_users (
  uid text PRIMARY KEY CHECK (uid <> ''),
  encoded_payload jsonb NOT NULL,
  payload_sha256 bytea NOT NULL CHECK (length(payload_sha256) = 32),
  promoted_at timestamptz
);

REVOKE ALL ON ALL TABLES IN SCHEMA clrs FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA clrs FROM PUBLIC;
COMMIT;
