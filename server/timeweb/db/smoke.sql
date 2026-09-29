-- Synthetic transaction: representative IDs, relations, and duplicate rejection.
BEGIN;
INSERT INTO clrs.accounts(uid, email_normalized) VALUES
  ('smoke-a', 'a@example.invalid'), ('smoke-b', 'b@example.invalid');
INSERT INTO clrs.profiles(uid, full_name, profile_details_saved, registration_complete)
  VALUES ('smoke-a', 'A', true, true), ('smoke-b', 'B', true, true);
INSERT INTO clrs.auth_identities(uid, provider, provider_subject)
  VALUES ('smoke-a', 'password', 'smoke-a');
INSERT INTO clrs.media_objects(media_id, owner_uid, purpose, object_key, thumbnail_key, mime_type, status)
  VALUES ('smoke-photo', 'smoke-a', 'profile', 'smoke/a.jpg', 'smoke/a-thumb.jpg', 'image/jpeg', 'ready');
INSERT INTO clrs.profile_photos(uid, media_id, ordinal, is_primary)
  VALUES ('smoke-a', 'smoke-photo', 0, true);
INSERT INTO clrs.chats(chat_id, uid_low, uid_high) VALUES ('smoke-chat', 'smoke-a', 'smoke-b');
INSERT INTO clrs.chat_members(chat_id, uid) VALUES
  ('smoke-chat', 'smoke-a'), ('smoke-chat', 'smoke-b');
INSERT INTO clrs.chat_messages(chat_id, message_id, sequence, sender_uid, body)
  VALUES ('smoke-chat', 'smoke-message', 1, 'smoke-a', 'test');
INSERT INTO clrs.meetings(meeting_id, organizer_uid, invited_uid, kind, title)
  VALUES ('smoke-meet', 'smoke-a', 'smoke-b', 'individual', 'test');
INSERT INTO clrs.meeting_members(meeting_id, uid) VALUES
  ('smoke-meet', 'smoke-a'), ('smoke-meet', 'smoke-b');
INSERT INTO clrs.meeting_messages(meeting_id, message_id, sequence, sender_uid)
  VALUES ('smoke-meet', 'smoke-meet-message', 1, 'smoke-b');
INSERT INTO clrs.friend_requests(requester_uid, recipient_uid, status)
  VALUES ('smoke-a', 'smoke-b', 'pending');
INSERT INTO clrs.notifications(uid, notification_id, source_event_id, kind)
  VALUES ('smoke-b', 'smoke-notice', 'smoke-event', 'friend_request');
INSERT INTO clrs.gift_catalog(gift_id, asset_path, name_key, price_ag)
  VALUES ('assets/gifts/1.png', 'assets/gifts/1.png', 'gift.one', 12);
INSERT INTO clrs.wallets(uid, balance_ag) VALUES ('smoke-a', 27), ('smoke-b', 0);
INSERT INTO clrs.wallet_ledger(entry_id, uid, delta_ag, balance_after_ag, reason)
  VALUES ('smoke-ledger', 'smoke-a', 27, 27, 'registration');
INSERT INTO clrs.gift_inventory(uid, gift_id, owned_quantity)
  VALUES ('smoke-a', 'assets/gifts/1.png', 1);
INSERT INTO clrs.posts(post_id, author_uid, body, status)
  VALUES ('smoke-post', 'smoke-a', 'test', 'published');
INSERT INTO clrs.post_comments(post_id, comment_id, author_uid, body)
  VALUES ('smoke-post', 'smoke-comment', 'smoke-b', 'test');
INSERT INTO clrs.legacy_documents(firebase_path, collection_path, document_id, encoded_payload, payload_sha256)
  VALUES ('users/deleted-parent/images/orphan', 'users/deleted-parent/images', 'orphan',
          '{"url":{"stringValue":"example"}}'::jsonb, decode(repeat('00', 32), 'hex'));

DO $$
DECLARE rejected boolean := false;
BEGIN
  BEGIN
    INSERT INTO clrs.chats(chat_id, uid_low, uid_high)
      VALUES ('smoke-duplicate-chat', 'smoke-a', 'smoke-b');
  EXCEPTION WHEN unique_violation THEN
    rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Duplicate chat pair was accepted'; END IF;

  rejected := false;
  BEGIN
    INSERT INTO clrs.notifications(uid, notification_id, source_event_id, kind)
      VALUES ('smoke-b', 'smoke-duplicate-notice', 'smoke-event', 'friend_request');
  EXCEPTION WHEN unique_violation THEN
    rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Duplicate notification source was accepted'; END IF;

  rejected := false;
  BEGIN
    INSERT INTO clrs.friend_requests(requester_uid, recipient_uid, status)
      VALUES ('smoke-a', 'smoke-a', 'pending');
  EXCEPTION WHEN check_violation THEN
    rejected := true;
  END;
  IF NOT rejected THEN RAISE EXCEPTION 'Self friend request was accepted'; END IF;
END $$;
ROLLBACK;
