ns = @edsc.map.L

ns.GranuleLayer = do (L,
                      GibsTileLayer = ns.GibsTileLayer,
                      projectPath=ns.interpolation.projectPath,
                      dateUtil = @edsc.util.date
                      dividePolygon = ns.sphericalPolygon.dividePolygon
                      ) ->


  isClockwise = (path) ->
    sum = 0
    len = path.length
    for i in [0...len]
      p0 = path[i]
      p1 = path[(i + 1) % len]
      sum += (p1.x - p0.x) * (p1.y + p0.y);
    sum > 0

  clockwise = (path) ->
    if isClockwise(path) then path else path.concat().reverse()

  counterclockwise = (path) ->
    if isClockwise(path) then path.concat().reverse() else path

  addPath = (ctx, path) ->
    len = path.length

    return if len < 2

    ctx.moveTo(path[0].x, path[0].y)
    ctx.lineTo(point.x, point.y) for point in path[1...]
    null

  clipped = (ctx, boundary, maskedPaths, drawnPaths, fn) ->
    ctx.save()
    if maskedPaths.length > 0
      ctx.beginPath()
      addPath(ctx, clockwise(boundary))
      for path in maskedPaths
        addPath(ctx, counterclockwise(path))
        ctx.clip()

    if drawnPaths.length > 0
      ctx.beginPath()
      for path in drawnPaths
        addPath(ctx, counterclockwise(path))
      ctx.clip()

    fn()
    ctx.restore()

    null

  # The first few methods are ported from L.TileLayer.Canvas, which is in our leaflet version but
  # seems to be removed from more recent versions.
  GranuleCanvasLayer = L.TileLayer.extend
    options:
      async: true

    setResults: (results) ->
      @_results = results
      @redraw()

    redraw: ->
      if @_map
        @_reset(hard: true)
        @_update()
        @_redrawTile(tile) for tile in @_tiles

      this

    _redrawTile: (tile) ->
      @drawTile(tile, tile._tilePoint, @_map._zoom)

    _createTile: ->
      tile = L.DomUtil.create('canvas', 'leaflet-tile')
      tile.width = tile.height = @options.tileSize
      tile.onselectstart = tile.onmousemove = L.Util.falseFn
      tile

    _loadTile: (tile, tilePoint) ->
      tile._layer = this

      # This line isn't in the leaflet source, which is seemingly a bug
      @_adjustTilePoint(tilePoint)

      tile._tilePoint = tilePoint

      @_redrawTile(tile)

      @tileDrawn() unless @options.async

    _granulePathsOverlappingTile: (granule, tileBounds) ->
      result = []
      map = @_map
      polygons = granule.getPolygons()
      if polygons?
        for polygon in polygons
          divided = dividePolygon(polygon[0])

          for interior in divided.interiors when tileBounds.intersects(interior)
            result.push(projectPath(map, interior, [], 'geodetic', 2, 5).boundary)

      rects = granule.getRectangles()
      if rects?
        for rect in rects
          if rect[0].lng > rect[1].lng
            divided = [[rect[0], L.latLng(rect[1].lat, 180)],
                       [L.latLng(rect[0].lat, -180), rect[1]]]
          else
            divided = [rect]

          paths = for box in divided
            [L.latLng(box[0].lat, box[0].lng), L.latLng(box[0].lat, box[1].lng),
             L.latLng(box[1].lat, box[1].lng), L.latLng(box[1].lat, box[0].lng),
             L.latLng(box[0].lat, box[0].lng)]

          for path in paths when tileBounds.intersects(path)
            result.push(projectPath(map, path, [], 'cartesian', 2, 5).boundary)

      result

    _clipPolygon: (ctx, str, tileBounds) ->
      intersects = false
      for polygon in dividePolygon(@_parsePolygon(str)).interiors

        bounds = new L.LatLngBounds()
        bounds.extend(latlng) for latlng in polygon

        if tileBounds.intersects(bounds)
          intersects = true
          path = (@_map.latLngToLayerPoint(ll) for ll in polygon)

          ctx.strokeStyle = "rgb(200,0,0)";
          ctx.moveTo(path[0].x, path[0].y)

          for point in path[1...]
            ctx.lineTo(point.x, point.y)

          ctx.closePath()
          #ctx.stroke()

      intersects

    _drawFootprint: (canvas, nwPoint, boundary, maskedPaths, drawnPaths) ->
      colors = ['rgba(255, 0, 0, 0.5)',
                'rgba(0, 255, 0, 0.5)',
                'rgba(0, 0, 255, 0.5)',
                'rgba(255, 255, 0, 0.5)',
                'rgba(255, 0, 255, 0.5)',
                'rgba(0, 255, 255, 0.5)',
                'rgba(255, 255, 255, 0.5)']

      ctx = canvas.getContext('2d')
      ctx.save()
      ctx.lineWidth = 1
      ctx.translate(-nwPoint.x, -nwPoint.y)
      tileSize = @options.tileSize
      ctx.strokeStyle = 'rgba(128, 128, 128, .2)'
      for path in drawnPaths
        ctx.moveTo(path[0].x, path[0].y)
        ctx.lineTo(p.x, p.y) for p in path[1...]
        ctx.closePath()
        ctx.stroke()
      clipped ctx, boundary, maskedPaths, [], ->
        for path in drawnPaths
          ctx.beginPath()
          ctx.moveTo(path[0].x, path[0].y)
          ctx.lineTo(p.x, p.y) for p in path[1...]
          ctx.closePath()
          # For debugging clip paths
          #ctx.fillStyle = colors[Math.abs(nwPoint.x + nwPoint.y) % colors.length]
          #ctx.fill()
          ctx.lineWidth = 2
          ctx.strokeStyle = 'rgba(0, 0, 0, 1)'
          ctx.stroke()
          ctx.lineWidth = 1
          ctx.strokeStyle = 'rgba(255, 255, 255, 1)'
          ctx.stroke()
      ctx.restore()

    getTileUrl: (tilePoint, date) ->
      L.TileLayer.prototype.getTileUrl.call(this, tilePoint) + "&time=#{date}" if @_url?

    _loadClippedImage: (canvas, tilePoint, date, nwPoint, boundary, maskedPaths, drawnPaths, retries=0) ->
      url = @getTileUrl(tilePoint, date)

      if url?
        image = new Image()
        image.onload = (e) =>
          ctx = canvas.getContext('2d')
          ctx.save()
          ctx.translate(-nwPoint.x, -nwPoint.y)
          clipped ctx, boundary, maskedPaths, drawnPaths, ->
            ctx.drawImage(image, nwPoint.x, nwPoint.y)

          ctx.restore()

          for path, i in drawnPaths
            @_drawFootprint(canvas, nwPoint, boundary, maskedPaths.concat(drawnPaths.slice(0, i)), [path])

        image.onerror = (e) =>
          if retries == 0
            @_loadClippedImage(canvas, tilePoint, date, nwPoint, boundary, maskedPaths, drawnPaths, 1)
          else
            console.error("Failed to load tile after 2 tries: #{url}")

        image.src = url
      else
        for path, i in drawnPaths
          @_drawFootprint(canvas, nwPoint, boundary, maskedPaths.concat(drawnPaths.slice(0, i)), [path])

    drawTile: (canvas, tilePoint) ->
      return unless @_results? && @_results.length > 0

      tileSize = @options.tileSize
      nwPoint = @_getTilePos(tilePoint)
      nePoint = nwPoint.add([tileSize, 0])
      sePoint = nwPoint.add([tileSize, tileSize])
      swPoint = nwPoint.add([0, tileSize])
      boundary = [nwPoint, nePoint, sePoint, swPoint]
      bounds = new L.latLngBounds(@_map.layerPointToLatLng(nwPoint),
                                  @_map.layerPointToLatLng(sePoint))

      #bounds.pad(0.1)

      date = null
      drawnPaths = []
      maskedPaths = []

      for granule, i in @_results
        start = granule.time_start?.substring(0, 10)

        paths = @_granulePathsOverlappingTile(granule, bounds)

        # Note: GIBS is currently ambiguous about which day to use
        if start != date
          if drawnPaths.length > 0
            @_loadClippedImage(canvas, tilePoint, date, nwPoint, boundary, maskedPaths, drawnPaths)

          maskedPaths = maskedPaths.concat(drawnPaths)
          drawnPaths = paths
          date = start
        else
          drawnPaths = drawnPaths.concat(paths)

      if drawnPaths.length > 0
        @_loadClippedImage(canvas, tilePoint, date, nwPoint, boundary, maskedPaths, drawnPaths)

        maskedPaths = maskedPaths.concat(drawnPaths)


      console.log "#{maskedPaths.length} Overlapping Granules [(#{bounds.getNorth()}, #{bounds.getWest()}), (#{bounds.getSouth()}, #{bounds.getEast()})]"
      @tileDrawn(canvas)

    tileDrawn: (tile) ->
      # If we do upgrade, this will break, as well as our tile reloading calls.
      # Tile loading seems to be handled via callbacks now.
      @_tileOnLoad.call(tile)

  class GranuleLayer extends GibsTileLayer
    constructor: (@granules, options) ->
      @_hasGibs = options?.product?

      super(options)

    onAdd: (map) ->
      super(map)

      @_resultsSubscription = @granules.results.subscribe(@_loadResults.bind(this))
      @_loadResults(@granules.results())

    onRemove: (map) ->
      @_destroyFootprintsLayer()

      super(map)

      @_resultsSubscription.dispose()
      @_results = null

    url: ->
      super() if @_hasGibs

    _destroyFootprintsLayer: ->
      @_footprintsLayer?.onRemove(@_map)
      @_footprintsLayer = null

    _createFootprintsLayer: ->
      @_destroyFootprintsLayer()
      @_footprintsLayer = L.featureGroup()
      @_footprintsLayer.onAdd(@_map)

    _buildLayerWithOptions: (newOptions) ->
      # GranuleCanvasLayer needs to handle time
      newOptions = L.extend({}, newOptions)
      delete newOptions.time

      layer = new GranuleCanvasLayer(@url(), @_toTileLayerOptions(newOptions))
      layer.setResults(@_results)
      layer

    _loadResults: (results) ->
      @_results = results
      @layer?.setResults(results)

      @_createFootprintsLayer()

      @_visualizePoints(results)

      bounds = @_footprintsLayer.getBounds()
      if bounds.getNorthEast()?
        @_map.fitBounds(bounds)

    _visualizePoints: (granules) ->
      footprints = @_footprintsLayer
      added = []
      for granule in granules
        for point in granule.getPoints() ? []
          pointStr = point.toString()
          if added.indexOf(pointStr) == -1
            added.push(pointStr)
            footprints.addLayer(L.circleMarker(point))