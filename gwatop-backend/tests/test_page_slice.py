from app.services.content_generators import slice_text_by_pages


def test_slice_text_by_form_feed_page_separator():
    text = "page1\n\n\f\n\npage2\n\n\f\n\npage3"

    assert slice_text_by_pages(text, "2") == "page2"
    assert slice_text_by_pages(text, "2-3") == "page2\n\npage3"


def test_invalid_page_range_falls_back_to_full_text():
    text = "page1\n\n\f\n\npage2"

    assert slice_text_by_pages(text, "abc") == text
