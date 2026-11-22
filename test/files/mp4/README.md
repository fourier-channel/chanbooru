Test file sources:

* https://danbooru.donmai.us/posts/2878908 (https://twitter.com/chan_co/status/913025965604749314)
* https://danbooru.donmai.us/posts/4270949 (https://twitter.com/chrone_co/status/1342709028401643520)
* https://danbooru.donmai.us/posts/5152189 (https://twitter.com/001_31_/status/1491405055563792386)
* https://github.com/jursonovicst/gradient/blob/master/player_validation_sequences/test_yuv420p10le_x265.mp4

test-304x304-anamorphic.mp4 is synthetic, made 2026-11-22 with:

    ffmpeg -f lavfi -i testsrc=s=304x304:r=10 -t 1 -vf setsar=27/32 -c:v libx264 -pix_fmt yuv420p -preset veryslow -crf 40 -movflags +faststart -fflags +bitexact -map_metadata -1 test-304x304-anamorphic.mp4

304 * 27/32 = 256.5: the muxer stores 256.5 in the tkhd box, exiftool reads Track1:ImageWidth as 256, and the decoded
frames display at 257 (FFmpeg#display_dimensions rounds).

test-304x304-anamorphic-width-off-by-two.mp4 and test-304x304-anamorphic-height-off-by-one.mp4 are copies of it with
the tkhd width set to 255 and the height to 303 by rewriting the box's two 16.16 fixed-point fields, to bound the
one-pixel tolerance in MediaFile::Video#container_dimensions_match?.
