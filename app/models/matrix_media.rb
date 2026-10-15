# frozen_string_literal: true

# fourier-auth's answer for one mxc (GATE 3 FOR POSTS, fourier-basis
# docs/design/GATE3_MATRIX_POSTS.md): who uploaded it, whether it is a site
# asset (an avatar, a room icon, an emote -- seen by every verified viewer),
# and the rooms it counts in (interned, MatrixRoom), as read from Synapse at
# snapshot (snapshot_head, snapshot_at). Written only by the placements feed
# (MatrixPlacements): a newer snapshot REPLACES the row, so a redaction or a
# room left behind lands; an older one is ignored. Kept for an mxc no post
# has yet, so a post made later is open to its rooms at once.
class MatrixMedia < ApplicationRecord
  self.table_name = "matrix_media"

  # An mxc URI: mxc://<server name>/<media id>.
  MXC = %r{\Amxc://[A-Za-z0-9.\-:\[\]]{1,255}/[A-Za-z0-9_-]{1,255}\z}
end
