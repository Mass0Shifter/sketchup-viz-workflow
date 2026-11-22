"""Inspection and view tools for SketchUp MCP (added by Nacham Tech).

These map to the /inspect, /view and /model/save routes in
sketchup_plugin/sketchup_mcp/inspect.rb. All lengths are millimetres and
entities are addressed by persistent id ("pid").
"""

from __future__ import annotations

from typing import Any, Awaitable, Callable

from mcp import types

_PID = {"type": "integer", "description": "Entity persistent id (pid) from outline/find/selection"}
_WALK = {"type": "integer", "description": "Max entities to visit on big models (default 300000)"}

INSPECT_TOOLS: list[types.Tool] = [
    types.Tool(
        name="model_summary",
        description=(
            "Start here. Overview of the model open in SketchUp: file, units, overall "
            "bounds in mm, unique vs placed face/edge counts, groups, component "
            "instances, nesting depth, materials, tags, scenes, selection."
        ),
        inputSchema={"type": "object", "properties": {"walk_limit": _WALK}},
    ),
    types.Tool(
        name="model_outline",
        description=(
            "Tree of groups and components (the model's structure, like the Outliner): "
            "name, definition, tag, material, size in mm, loose geometry. Repeated "
            "components (3+ of the same definition at a level) are collapsed into one "
            "entry with a count. Pass pid to expand one branch deeper."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "pid": _PID,
                "max_depth": {"type": "integer", "description": "Levels to expand (default 3)"},
                "max_children": {"type": "integer", "description": "Max entries per level (default 150)"},
                "collapse_repeats": {"type": "boolean", "description": "Collapse repeated components (default true)"},
            },
        },
    ),
    types.Tool(
        name="list_scenes",
        description="Scenes (pages): camera, style, which tags each scene hides, which is active.",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="list_tags",
        description="Tags (layers) with visibility, folder, colour and how many entities use each.",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="list_materials_detailed",
        description="Materials with colour, opacity, texture file and real-world texture size, and usage count.",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="model_health",
        description=(
            "Model hygiene check: loose top-level geometry, raw geometry on tags, stray edges, "
            "tiny faces, hidden/empty containers, unused definitions, materials and tags."
        ),
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="find_entities",
        description=(
            "Search the whole model (including inside groups/components) by name or "
            "definition name substring, and/or filter by type, tag or material. "
            "Returns pid, path and size for each hit."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Case-insensitive name substring"},
                "type": {"type": "string", "enum": ["group", "component", "face", "edge"]},
                "tag": {"type": "string"},
                "material": {"type": "string"},
                "limit": {"type": "integer", "description": "Max results (default 100)"},
                "walk_limit": _WALK,
            },
        },
    ),
    types.Tool(
        name="get_entity",
        description=(
            "Full detail for one entity by pid: transform, bounds, contents, solid/volume, "
            "lock/hidden state, parent and attribute dictionaries."
        ),
        inputSchema={"type": "object", "properties": {"pid": _PID}, "required": ["pid"]},
    ),
    types.Tool(
        name="get_selection",
        description="What the user currently has selected in SketchUp.",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="select_entities",
        description=(
            "Select entities by pid in SketchUp so the user sees them highlighted "
            "(only entities in the currently open editing context can be selected)."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "pids": {"type": "array", "items": {"type": "integer"}},
                "zoom": {"type": "boolean", "description": "Zoom the view to the selection"},
            },
            "required": ["pids"],
        },
    ),
    types.Tool(
        name="capture_view",
        description=(
            "Take a picture of the model and return it as an image you can look at. "
            "Use view=iso/top/front/back/left/right/bottom for a standard view of the whole "
            "model (or of one entity with pid), scene=<name> to show a saved scene, or nothing "
            "for the user's current view. The user's camera is restored afterwards unless "
            "keep_view is true (activating a scene is not undone)."
        ),
        inputSchema={
            "type": "object",
            "properties": {
                "view": {"type": "string", "enum": ["current", "iso", "top", "bottom", "front", "back", "left", "right"]},
                "scene": {"type": "string"},
                "pid": _PID,
                "zoom_extents": {"type": "boolean"},
                "perspective": {"type": "boolean"},
                "width": {"type": "integer", "description": "Pixels (default 1280)"},
                "height": {"type": "integer", "description": "Pixels (default 800)"},
                "format": {"type": "string", "enum": ["jpg", "png"]},
                "keep_view": {"type": "boolean"},
            },
        },
    ),
    types.Tool(
        name="save_model",
        description=(
            "Save the open model. With save_copy_path, writes a copy (.skp) and leaves the "
            "open file untouched. Only call when the user asks to save."
        ),
        inputSchema={
            "type": "object",
            "properties": {"save_copy_path": {"type": "string", "description": "Absolute Windows path ending in .skp"}},
        },
    ),
]

# name -> (method, route)
_ROUTES: dict[str, tuple[str, str]] = {
    "model_summary": ("GET", "/inspect/summary"),
    "model_outline": ("POST", "/inspect/outline"),
    "list_scenes": ("GET", "/inspect/scenes"),
    "list_tags": ("GET", "/inspect/tags"),
    "list_materials_detailed": ("GET", "/inspect/materials"),
    "model_health": ("GET", "/inspect/health"),
    "find_entities": ("POST", "/inspect/find"),
    "get_entity": ("POST", "/inspect/entity"),
    "get_selection": ("GET", "/inspect/selection"),
    "select_entities": ("POST", "/view/select"),
    "capture_view": ("POST", "/view/capture"),
    "save_model": ("POST", "/model/save"),
}


async def call_inspect_tool(
    name: str,
    arguments: dict[str, Any],
    su_get: Callable[..., Awaitable[Any]],
    su_post: Callable[..., Awaitable[Any]],
    ok: Callable[[Any], list],
    timeout: float | None = None,
) -> list | None:
    """Return MCP content for an inspection tool, or None if `name` isn't one."""
    route = _ROUTES.get(name)
    if route is None:
        return None
    method, path = route
    args = {k: v for k, v in (arguments or {}).items() if v is not None}
    if name == "capture_view" and args.get("view") == "current":
        args.pop("view")
    data = await (su_get(path, args) if method == "GET" else su_post(path, args))

    if name == "capture_view":
        img = data.pop("image_base64")
        return [
            types.ImageContent(type="image", data=img, mimeType=data.get("mime", "image/jpeg")),
            *ok(data),
        ]
    return ok(data)
