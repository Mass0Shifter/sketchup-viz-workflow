"""Tests for the inspection/view tools (src/sketchup_mcp/inspect_tools.py)."""

import pytest

from sketchup_mcp import server
from sketchup_mcp.inspect_tools import INSPECT_TOOLS, call_inspect_tool


def _ok(data):
    return server.ok(data)


@pytest.mark.asyncio
async def test_routes_get_and_post():
    calls = []

    async def su_get(path, params=None):
        calls.append(("GET", path, params))
        return {"title": "Consulate"}

    async def su_post(path, body=None):
        calls.append(("POST", path, body))
        return {"count": 0}

    await call_inspect_tool("model_summary", {}, su_get, su_post, _ok)
    await call_inspect_tool("find_entities", {"query": "door", "limit": None}, su_get, su_post, _ok)
    assert calls[0][:2] == ("GET", "/inspect/summary")
    assert calls[1] == ("POST", "/inspect/find", {"query": "door"})  # None values dropped


@pytest.mark.asyncio
async def test_capture_view_returns_image():
    async def su_post(path, body=None):
        assert body == {}  # view=current is the default and is not sent
        return {"mime": "image/png", "image_base64": "AAAA", "width": 1, "height": 1}

    out = await call_inspect_tool("capture_view", {"view": "current"}, None, su_post, _ok)
    assert out[0].type == "image" and out[0].data == "AAAA" and out[0].mimeType == "image/png"
    assert "image_base64" not in out[1].text


@pytest.mark.asyncio
async def test_unknown_tool_returns_none():
    assert await call_inspect_tool("create_box", {}, None, None, _ok) is None


@pytest.mark.asyncio
async def test_list_tools_hides_construction_by_default():
    names = [t.name for t in await server.list_tools()]
    assert "model_outline" in names and "execute_ruby" in names
    assert "create_roof_truss" not in names
    assert len(names) == len(set(names))
    assert {t.name for t in INSPECT_TOOLS} <= set(names)
