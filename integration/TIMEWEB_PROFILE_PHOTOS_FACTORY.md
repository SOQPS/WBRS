Native profile-photo setup
==========================

The app now mounts a lazy, default-off native photo reader behind the existing
operator preview guard. `CLRS_RUNTIME_PROFILE_PHOTOS_ENABLED=1` additionally
requires the existing canonical runtime flags and
`CLRS_RUNTIME_PROFILE_PHOTO_ORDER_POLICY=reviewed-source-document-id-binary-asc-v1`.
The ordering value must match `runtime_profile_photos.GALLERY_ORDER_POLICY`.

Construction verifies the existing authenticated completed media acknowledgement,
including its fixed source/archive pins and approved full raw SQL/S3 readback
proof. That same genuine acknowledgement supplies the trusted completed source
capability; SQL alone or a caller-created dataclass does not. This remains an
archival import with `consistent=false`, not a final write barrier or cutover.

Only the dedicated read-only S3 key, read-only control-plane token and existing
native runtime SQL configuration are accepted. Session, reference and completed
receipt keys must be distinct. There is no migration-key fallback, public URL,
SQL/S3 request during setup, or new paid resource. A new owned private temporary
directory holds anonymous verified original streams. Closing the HTTP reader
aborts its downloads and SQL work and cleans up that directory.

Required existing media settings use the `CLRS_LEGACY_MEDIA_*` names from the
private media setup; enabling native photos does not enable legacy media routes.
Missing/bad photo flag leaves routes at 404. Invalid proof/configuration with an
explicitly enabled reader returns 503 without weakening authorization.

Five focused synthetic setup/cleanup scenarios cover default-off construction,
authentic receipt reuse, changed ciphertext, policy/key separation and resource
cleanup. They do not prove deployed native login, current real photo acceptance
or cutover. The photo association projector and controlled live readback remain
separate prerequisites.
