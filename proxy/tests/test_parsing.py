import pytest

from abconnect_proxy.parsing import ItemUnusable, parse_item


def item(media: dict | None = None):
    payload = {
        "id": "li_abc",
        "media": {
            "duration": 3600.0,
            "coverPath": "/data/cover.jpg",
            "metadata": {"title": "Der Process", "authorName": "Franz Kafka"},
            "audioFiles": [
                {
                    "index": 1,
                    "ino": "9001",
                    "codec": "aac",
                    "duration": 3600.0,
                    "metadata": {"filename": "buch.m4b", "size": 28800000},
                }
            ],
            "chapters": [
                {"id": 0, "start": 0, "end": 1800, "title": "Verhaftung"},
                {"id": 1, "start": 1800, "end": 3600, "title": "Erste Untersuchung"},
            ],
        },
    }
    if media is not None:
        payload["media"].update(media)
    return payload


class TestParseItem:
    def test_reads_title_author_files_and_chapters(self):
        parsed = parse_item(item())
        assert (parsed.title, parsed.author) == ("Der Process", "Franz Kafka")
        assert parsed.duration == 3600.0
        assert [f.ino for f in parsed.files] == ["9001"]
        assert [c.title for c in parsed.chapters] == [
            "Verhaftung",
            "Erste Untersuchung",
        ]

    def test_falls_back_to_the_authors_list(self):
        parsed = parse_item(
            item(
                media={
                    "metadata": {
                        "title": "X",
                        "authors": [{"name": "A"}, {"name": "B"}],
                    }
                }
            )
        )
        assert parsed.author == "A, B"

    def test_orders_files_by_index(self):
        files = [
            {
                "index": 2,
                "ino": "2",
                "codec": "mp3",
                "duration": 10,
                "metadata": {"filename": "b", "size": 1},
            },
            {
                "index": 1,
                "ino": "1",
                "codec": "mp3",
                "duration": 10,
                "metadata": {"filename": "a", "size": 1},
            },
        ]
        parsed = parse_item(item(media={"audioFiles": files}))
        assert [f.ino for f in parsed.files] == ["1", "2"]

    def test_skips_files_marked_invalid(self):
        files = [
            {
                "index": 1,
                "ino": "1",
                "codec": "aac",
                "duration": 10,
                "metadata": {"filename": "a", "size": 1},
            },
            {
                "index": 2,
                "ino": "2",
                "codec": "aac",
                "duration": 10,
                "invalid": True,
                "metadata": {},
            },
        ]
        parsed = parse_item(item(media={"audioFiles": files}))
        assert [f.ino for f in parsed.files] == ["1"]

    def test_derives_duration_from_the_files_when_media_has_none(self):
        parsed = parse_item(item(media={"duration": None}))
        assert parsed.duration == 3600.0

    @pytest.mark.parametrize(
        "media, expected",
        [
            ({"audioFiles": []}, "no audio files"),
            (
                {
                    "audioFiles": [
                        {
                            "index": 1,
                            "ino": "1",
                            "codec": "aac",
                            "duration": 0,
                            "metadata": {},
                        }
                    ]
                },
                "without duration",
            ),
            (
                {
                    "audioFiles": [
                        {"index": 1, "codec": "aac", "duration": 10, "metadata": {}}
                    ]
                },
                "without ino",
            ),
        ],
    )
    def test_reports_unusable_items_in_plain_language(self, media, expected):
        with pytest.raises(ItemUnusable) as error:
            parse_item(item(media=media))
        assert expected.lower() in str(error.value).lower()

    def test_rejects_a_response_without_an_item(self):
        with pytest.raises(ItemUnusable):
            parse_item({})
