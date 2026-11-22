# frozen_string_literal: true

# Read-only model inspection (plus view capture / selection / save) for the
# SketchUp MCP bridge. All lengths are returned in millimetres; SketchUp's
# internal unit is inches.
#
# Entities are addressed by persistent_id ("pid"), which survives save/reopen,
# unlike entityID.

require 'base64'

module SU_MCP
  module Inspect
    module_function

    MM = 25.4
    WALK_LIMIT_DEFAULT = 300_000

    # ------------------------------------------------------------------ helpers

    def model
      Sketchup.active_model
    end

    def mm(v)
      (v.to_f * MM).round(1)
    end

    def pt_mm(p)
      [mm(p.x), mm(p.y), mm(p.z)]
    end

    def bbox_info(bb)
      return nil if bb.nil? || bb.empty?
      {
        min_mm: pt_mm(bb.min),
        max_mm: pt_mm(bb.max),
        # SketchUp: width = X, height = Y, depth = Z
        size_mm: { x: mm(bb.width), y: mm(bb.height), z: mm(bb.depth) }
      }
    end

    def container?(e)
      e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
    end

    def definition_of(e)
      e.definition
    end

    def tag_name(e)
      e.layer ? e.layer.name : nil
    end

    def mat_name(m)
      m ? m.display_name : nil
    end

    def find_pid(pid)
      pid = pid.to_i
      raise 'pid is required' if pid <= 0
      e = model.find_entity_by_persistent_id(pid)
      raise "No entity with pid #{pid}" unless e
      e
    end

    def length_unit_name
      %w[inches feet millimetres centimetres metres yards][model.options['UnitsOptions']['LengthUnit'].to_i] || 'unknown'
    rescue StandardError
      'unknown'
    end

    def brief(e)
      h = { pid: e.persistent_id, type: e.typename }
      case e
      when Sketchup::Group, Sketchup::ComponentInstance
        h[:name] = e.name
        h[:definition] = e.definition.name if e.is_a?(Sketchup::ComponentInstance)
        h[:tag] = tag_name(e)
        h[:material] = mat_name(e.material)
        h[:bounds] = bbox_info(e.bounds)
      when Sketchup::Face
        h[:area_m2] = (e.area * MM * MM / 1_000_000.0).round(4)
        h[:tag] = tag_name(e)
        h[:material] = mat_name(e.material)
        h[:back_material] = mat_name(e.back_material)
      when Sketchup::Edge
        h[:length_mm] = mm(e.length)
        h[:tag] = tag_name(e)
      else
        h[:tag] = tag_name(e) if e.respond_to?(:layer)
      end
      h
    end

    # Depth-first walk over everything as it is placed in the model (instances
    # are expanded each time they occur). Yields (entity, path_names, depth).
    # Stops after `limit` entities and returns true if truncated.
    def walk(entities, limit, path = [], depth = 0, state = { n: 0 }, &blk)
      entities.each do |e|
        state[:n] += 1
        return true if state[:n] > limit
        blk.call(e, path, depth)
        next unless container?(e)
        label = e.name.to_s.empty? ? definition_of(e).name : e.name
        return true if walk(definition_of(e).entities, limit, path + [label], depth + 1, state, &blk)
      end
      false
    end

    # ------------------------------------------------------------------ summary

    def summary(params = {})
      m = model
      limit = (params['walk_limit'] || WALK_LIMIT_DEFAULT).to_i

      # Unique geometry: each definition counted once.
      unique = { faces: 0, edges: 0 }
      count_raw = lambda do |ents|
        ents.each do |e|
          unique[:faces] += 1 if e.is_a?(Sketchup::Face)
          unique[:edges] += 1 if e.is_a?(Sketchup::Edge)
        end
      end
      count_raw.call(m.entities)
      defs = m.definitions.reject(&:image?)
      defs.each { |d| count_raw.call(d.entities) }

      # Placed geometry: everything as rendered.
      placed = Hash.new(0)
      max_depth = 0
      truncated = walk(m.entities, limit) do |e, _path, depth|
        max_depth = depth if depth > max_depth
        case e
        when Sketchup::Face then placed[:faces] += 1
        when Sketchup::Edge then placed[:edges] += 1
        when Sketchup::Group then placed[:groups] += 1
        when Sketchup::ComponentInstance then placed[:component_instances] += 1
        end
      end

      size = begin
        m.path.empty? ? nil : (File.size(m.path) / 1024.0 / 1024.0).round(2)
      rescue StandardError
        nil
      end

      {
        title: m.title,
        path: m.path,
        file_size_mb: size,
        modified_since_save: m.modified?,
        sketchup_version: Sketchup.version,
        display_length_unit: length_unit_name,
        bounds: bbox_info(m.bounds),
        top_level_entities: m.entities.length,
        unique_geometry: unique,
        placed_geometry: placed.merge(max_nesting_depth: max_depth, truncated: truncated),
        component_definitions: m.definitions.count { |d| !d.group? && !d.image? },
        group_definitions: m.definitions.count(&:group?),
        materials: m.materials.length,
        tags: m.layers.length,
        scenes: m.pages.length,
        selected_scene: m.pages.selected_page&.name,
        selection_count: m.selection.length,
        georeferenced: m.georeferenced?
      }
    end

    # ------------------------------------------------------------------ outline

    def outline(params = {})
      max_depth = (params['max_depth'] || 3).to_i
      max_children = (params['max_children'] || 150).to_i
      collapse = params.key?('collapse_repeats') ? params['collapse_repeats'] : true

      if params['pid']
        root = find_pid(params['pid'])
        raise 'pid must be a group or component instance' unless container?(root)
        return node(root, 0, max_depth, max_children, collapse)
      end

      ents = model.entities
      {
        model: model.title,
        loose_geometry: loose_counts(ents),
        children: children_nodes(ents, 0, max_depth, max_children, collapse)
      }
    end

    def loose_counts(ents)
      f = 0
      e = 0
      ents.each do |x|
        f += 1 if x.is_a?(Sketchup::Face)
        e += 1 if x.is_a?(Sketchup::Edge)
      end
      { faces: f, edges: e }
    end

    def children_nodes(ents, depth, max_depth, max_children, collapse)
      containers = ents.select { |e| container?(e) }
      items = []
      if collapse
        groups = containers.select { |e| e.is_a?(Sketchup::Group) }
        comps = containers.select { |e| e.is_a?(Sketchup::ComponentInstance) }
        comps.group_by(&:definition).each do |defn, insts|
          if insts.length >= 3
            first = insts.first
            n = node(first, depth, max_depth, max_children, collapse)
            n[:repeated_instances] = insts.length
            n[:instance_pids] = insts.first(20).map(&:persistent_id)
            n[:note] = 'collapsed: showing first instance' if insts.length > 1
            items << n
          else
            insts.each { |i| items << node(i, depth, max_depth, max_children, collapse) }
          end
        end
        groups.each { |g| items << node(g, depth, max_depth, max_children, collapse) }
      else
        containers.each { |c| items << node(c, depth, max_depth, max_children, collapse) }
      end
      total = items.length
      items = items.first(max_children)
      items << { truncated: total - max_children } if total > max_children
      items
    end

    def node(e, depth, max_depth, max_children, collapse)
      d = definition_of(e)
      h = {
        pid: e.persistent_id,
        type: e.is_a?(Sketchup::Group) ? 'group' : 'component',
        name: e.name,
        definition: d.name,
        tag: tag_name(e),
        material: mat_name(e.material),
        hidden: e.hidden?,
        size_mm: bbox_info(e.bounds)&.dig(:size_mm),
        loose_geometry: loose_counts(d.entities)
      }
      h[:definition_instances] = d.instances.length if e.is_a?(Sketchup::ComponentInstance)
      kids = d.entities.count { |x| container?(x) }
      if depth + 1 < max_depth && kids.positive?
        h[:children] = children_nodes(d.entities, depth + 1, max_depth, max_children, collapse)
      else
        h[:child_containers] = kids
      end
      h
    end

    # ------------------------------------------------------------------ scenes / tags / materials

    def scenes(_params = {})
      m = model
      m.pages.map do |pg|
        cam = pg.camera
        {
          name: pg.name,
          label: pg.respond_to?(:label) ? pg.label : pg.name,
          description: pg.description,
          selected: m.pages.selected_page == pg,
          stores_camera: pg.use_camera?,
          stores_tag_visibility: pg.use_hidden_layers?,
          style: pg.style&.name,
          camera: cam && {
            eye_mm: pt_mm(cam.eye), target_mm: pt_mm(cam.target),
            perspective: cam.perspective?, fov: (cam.perspective? ? cam.fov.round(1) : nil)
          },
          hidden_tags: pg.layers.map(&:name)
        }
      end
    end

    def usage_counts(limit)
      tags = Hash.new(0)
      mats = Hash.new(0)
      # Count unique usage per definition (cheap) + root.
      tally = lambda do |ents|
        ents.each do |e|
          tags[e.layer.name] += 1 if e.respond_to?(:layer) && e.layer
          if e.respond_to?(:material) && e.material
            mats[e.material.name] += 1
          end
          if e.is_a?(Sketchup::Face) && e.back_material
            mats[e.back_material.name] += 1
          end
        end
      end
      tally.call(model.entities)
      model.definitions.each { |d| tally.call(d.entities) unless d.image? }
      [tags, mats]
    end

    def tags(params = {})
      tag_use, = usage_counts(params['walk_limit'] || WALK_LIMIT_DEFAULT)
      model.layers.map do |l|
        {
          name: l.name,
          visible: l.visible?,
          folder: (l.respond_to?(:folder) && l.folder ? l.folder.name : nil),
          color: (c = l.color) && [c.red, c.green, c.blue],
          used_by_entities: tag_use[l.name]
        }
      end
    end

    def materials(_params = {})
      _, mat_use = usage_counts(WALK_LIMIT_DEFAULT)
      model.materials.map do |mat|
        c = mat.color
        tex = mat.texture
        {
          name: mat.name,
          display_name: mat.display_name,
          color_rgb: [c.red, c.green, c.blue],
          alpha: mat.alpha.round(2),
          texture: tex && {
            file: File.basename(tex.filename.to_s),
            size_mm: [mm(tex.width), mm(tex.height)],
            pixels: [tex.image_width, tex.image_height]
          },
          used_by_entities: mat_use[mat.name]
        }
      end
    end

    # ------------------------------------------------------------------ health

    def health(_params = {})
      m = model
      issues = Hash.new(0)
      root_loose = loose_counts(m.entities)

      check = lambda do |ents|
        ents.each do |e|
          case e
          when Sketchup::Edge
            issues[:stray_edges] += 1 if e.faces.empty?
            issues[:raw_geometry_on_tags] += 1 if e.layer != m.layers[0]
          when Sketchup::Face
            issues[:tiny_faces_under_1mm2] += 1 if e.area * MM * MM < 1.0
            issues[:raw_geometry_on_tags] += 1 if e.layer != m.layers[0]
          when Sketchup::Group, Sketchup::ComponentInstance
            issues[:hidden_containers] += 1 if e.hidden?
            issues[:empty_containers] += 1 if e.definition.entities.length.zero?
          end
          issues[:hidden_geometry] += 1 if (e.is_a?(Sketchup::Face) || e.is_a?(Sketchup::Edge)) && e.hidden?
        end
      end
      check.call(m.entities)
      m.definitions.each { |d| check.call(d.entities) unless d.image? }

      unused_defs = m.definitions.select { |d| !d.image? && !d.group? && d.instances.empty? }.map(&:name)
      tag_use, mat_use = usage_counts(WALK_LIMIT_DEFAULT)
      unused_mats = m.materials.select { |mt| mat_use[mt.name].zero? }.map(&:name)
      unused_tags = m.layers.to_a[1..-1].to_a.select { |l| tag_use[l.name].zero? }.map(&:name)

      notes = []
      notes << "#{root_loose[:faces]} faces / #{root_loose[:edges]} edges sit loose at the top level (not grouped)" if (root_loose[:faces] + root_loose[:edges]).positive?
      notes << "#{issues[:raw_geometry_on_tags]} raw faces/edges are on a tag other than Untagged (best practice: tag groups/components, keep raw geometry Untagged)" if issues[:raw_geometry_on_tags].positive?
      notes << "#{unused_defs.length} unused component definitions, #{unused_mats.length} unused materials — Purge Unused would shrink the file" if (unused_defs.length + unused_mats.length).positive?
      notes << "#{issues[:stray_edges]} stray edges (edges bounding no face)" if issues[:stray_edges].positive?

      {
        root_loose_geometry: root_loose,
        counts: issues,
        unused_component_definitions: { count: unused_defs.length, names: unused_defs.first(50) },
        unused_materials: { count: unused_mats.length, names: unused_mats.first(50) },
        unused_tags: { count: unused_tags.length, names: unused_tags.first(50) },
        notes: notes
      }
    end

    # ------------------------------------------------------------------ find / entity / selection

    def find(params = {})
      q = params['query'].to_s.downcase
      want_type = params['type'] # group | component | face | edge
      want_tag = params['tag']
      want_mat = params['material']
      limit = (params['limit'] || 100).to_i
      walk_limit = (params['walk_limit'] || WALK_LIMIT_DEFAULT).to_i
      hits = []
      seen = {}
      truncated = walk(model.entities, walk_limit) do |e, path, _depth|
        next if hits.length >= limit
        t = case e
            when Sketchup::Group then 'group'
            when Sketchup::ComponentInstance then 'component'
            when Sketchup::Face then 'face'
            when Sketchup::Edge then 'edge'
            end
        next unless t
        next if want_type && want_type != t
        next if want_tag && tag_name(e) != want_tag
        next if want_mat && mat_name(e.material) != want_mat && (e.respond_to?(:material) ? e.material&.name : nil) != want_mat
        if !q.empty?
          names = [e.respond_to?(:name) ? e.name : nil]
          names << e.definition.name if container?(e)
          next unless names.compact.any? { |n| n.downcase.include?(q) }
        elsif !want_type && !want_tag && !want_mat
          next
        end
        next if seen[e.persistent_id]
        seen[e.persistent_id] = true
        hits << brief(e).merge(path: path)
      end
      { count: hits.length, limit_reached: hits.length >= limit, walk_truncated: truncated, results: hits }
    end

    def entity(params = {})
      e = find_pid(params['pid'])
      h = brief(e)
      if container?(e)
        t = e.transformation
        h[:origin_mm] = pt_mm(t.origin)
        h[:axes] = { x: t.xaxis.to_a.map { |v| v.round(4) }, y: t.yaxis.to_a.map { |v| v.round(4) }, z: t.zaxis.to_a.map { |v| v.round(4) } }
        d = e.definition
        h[:definition_instances] = d.instances.length
        h[:contents] = Hash.new(0).tap { |c| d.entities.each { |x| c[x.typename] += 1 } }
        h[:is_solid] = e.manifold?
        h[:volume_m3] = (e.volume * (MM**3) / 1e9).round(4) if e.manifold? && e.volume.positive?
        h[:locked] = e.locked?
        h[:hidden] = e.hidden?
        h[:definition_description] = d.description unless d.description.to_s.empty?
      end
      if e.is_a?(Sketchup::Face)
        h[:normal] = e.normal.to_a.map { |v| v.round(4) }
        h[:vertices] = e.vertices.length
        h[:inner_loops] = e.loops.length - 1
      end
      parent = e.parent
      h[:parent] = parent.is_a?(Sketchup::Model) ? 'model' : parent.name
      dicts = e.attribute_dictionaries
      if dicts
        h[:attributes] = dicts.each_with_object({}) do |dict, acc|
          vals = {}
          dict.each_pair do |k, v|
            break if vals.length >= 40
            vals[k] = v.is_a?(String) ? v[0, 200] : v.to_s[0, 200]
          end
          acc[dict.name] = vals
        end
      end
      h
    end

    def selection(_params = {})
      sel = model.selection
      { count: sel.length, items: sel.first(200).map { |e| brief(e) } }
    end

    def select(params = {})
      pids = Array(params['pids']).map(&:to_i)
      sel = model.selection
      sel.clear
      found = pids.map { |p| model.find_entity_by_persistent_id(p) }.compact
      # Only entities in the active editing context can be selected.
      ctx_parent = model.active_entities.parent
      selectable = found.select { |e| e.parent == ctx_parent }
      sel.add(selectable) unless selectable.empty?
      model.active_view.zoom(sel) if params['zoom'] && !sel.empty?
      { selected: sel.length, not_found: pids.length - found.length, not_in_active_context: found.length - selectable.length }
    end

    # ------------------------------------------------------------------ view capture

    VIEW_DIRS = {
      'iso'    => [-1, -1, 1],
      'top'    => [0, 0, 1],
      'bottom' => [0, 0, -1],
      'front'  => [0, -1, 0],
      'back'   => [0, 1, 0],
      'left'   => [-1, 0, 0],
      'right'  => [1, 0, 0]
    }.freeze

    # World-space placement of an entity: its parent transformation is found
    # by walking the model from the root (first placement if a component is
    # used more than once). Entity#bounds is in the parent's local space, so
    # nested groups/components need this for camera framing.
    def world_transform_of(target)
      search = lambda do |ents, tr|
        ents.each do |e|
          return tr if e == target
          next unless container?(e)
          found = search.call(definition_of(e).entities, tr * e.transformation)
          return found if found
        end
        nil
      end
      search.call(model.entities, Geom::Transformation.new) || Geom::Transformation.new
    end

    def world_bounds(e)
      parent_tr = world_transform_of(e)
      bb = Geom::BoundingBox.new
      local = e.bounds
      8.times { |i| bb.add(local.corner(i).transform(parent_tr)) }
      bb
    end

    # Point the camera along `dir` at `bb` and fit it to the frame.
    def frame_camera(bb, dir, up, persp, aspect)
      center = bb.center
      radius = [bb.diagonal / 2.0, 1].max
      if persp
        fov = 35.0
        half = (fov / 2.0).degrees
        half = Math.atan(Math.tan(half) * aspect) if aspect < 1 # horizontal limits on tall frames
        dist = radius / Math.sin(half) * 1.05
      else
        dist = radius * 4
      end
      eye = center.offset(dir, dist)
      cam = Sketchup::Camera.new(eye, center, up, persp)
      if persp
        cam.fov = 35
      else
        cam.height = radius * 2 * 1.05 / [aspect, 1.0].min
      end
      cam
    end

    def copy_camera(c)
      cam = Sketchup::Camera.new(c.eye, c.target, c.up, c.perspective?)
      if c.perspective?
        cam.fov = c.fov
      else
        cam.height = c.height
      end
      cam
    end

    def capture_view(params = {})
      m = model
      view = m.active_view
      keep = params['keep_view'] ? true : false
      saved_cam = copy_camera(view.camera)

      if params['scene']
        pg = m.pages[params['scene'].to_s]
        raise "Scene not found: #{params['scene']}" unless pg
        # Activating a scene changes tag visibility as the scene defines; this is
        # what the user would see, so it is not undone.
        m.pages.selected_page = pg
        view.camera = copy_camera(pg.camera) if pg.use_camera?
      end

      width = (params['width'] || 1280).to_i.clamp(200, 3840)
      height = (params['height'] || 800).to_i.clamp(200, 2160)
      aspect = width.to_f / height

      vname = params['view'].to_s
      if VIEW_DIRS.key?(vname)
        target_ent = params['pid'] ? find_pid(params['pid']) : nil
        dir = Geom::Vector3d.new(*VIEW_DIRS[vname]).normalize
        up = %w[top bottom].include?(vname) ? Geom::Vector3d.new(0, 1, 0) : Geom::Vector3d.new(0, 0, 1)
        persp = vname == 'iso' ? (params.key?('perspective') ? params['perspective'] : true) : (params['perspective'] || false)
        if target_ent
          view.camera = frame_camera(world_bounds(target_ent), dir, up, persp, aspect)
        else
          cam = Sketchup::Camera.new(m.bounds.center.offset(dir, [m.bounds.diagonal, 1].max * 2), m.bounds.center, up, persp)
          cam.fov = 35 if persp
          view.camera = cam
          view.zoom_extents
        end
      elsif params['pid']
        c = view.camera
        dir = c.eye - c.target
        dir = Geom::Vector3d.new(-1, -1, 1) unless dir.valid?
        view.camera = frame_camera(world_bounds(find_pid(params['pid'])), dir.normalize, c.up, c.perspective?, aspect)
      elsif params['zoom_extents']
        view.zoom_extents
      end

      fmt = params['format'].to_s == 'png' ? 'png' : 'jpg'
      file = File.join(Sketchup.temp_dir, "su_mcp_capture_#{Process.pid}_#{(Time.now.to_f * 1000).to_i}.#{fmt}")
      opts = { filename: file, width: width, height: height, antialias: true }
      opts[:compression] = 0.85 if fmt == 'jpg'
      view.invalidate
      ok = view.write_image(opts)
      raise 'view.write_image failed' unless ok && File.exist?(file)
      data = File.binread(file)
      File.delete(file) rescue nil

      info = {
        camera: { eye_mm: pt_mm(view.camera.eye), target_mm: pt_mm(view.camera.target), perspective: view.camera.perspective? },
        scene: m.pages.selected_page&.name
      }
      view.camera = saved_cam unless keep || params['scene']

      {
        mime: fmt == 'png' ? 'image/png' : 'image/jpeg',
        width: width, height: height,
        image_base64: Base64.strict_encode64(data),
        info: info
      }
    end

    # ------------------------------------------------------------------ save

    def save(params = {})
      m = model
      raise 'Model has never been saved; give save_copy_path' if m.path.empty? && !params['save_copy_path']
      if params['save_copy_path']
        path = params['save_copy_path'].to_s
        raise 'save_copy_path must end in .skp' unless path.downcase.end_with?('.skp')
        ok = m.save_copy(path)
        { saved_copy: ok, path: path }
      else
        ok = m.save
        { saved: ok, path: m.path }
      end
    end
  end
end
