import math, times, tables, lists, sets

import opengl

import nimx.window
import nimx.matrixes
import nimx.image
import nimx.animation
import nimx.system_logger
import nimx.portable_gl
import nimx.context
import nimx.keyboard
import nimx.view_event_handling_new

import rod.viewport
import rod.node
import rod.component
import rod.component.camera
import rod.quaternion

#from collections import deque
#from pyglet import image
#from pyglet.gl import *
#from pyglet.graphics import TextureGroup
#from pyglet.window import key, mouse

type iVec3 = TVector[3, GLint]


const TICKS_PER_SEC = 60

# Size of sectors used to ease block loading.
const SECTOR_SIZE = 16

const WALKING_SPEED = 5
const FLYING_SPEED = 15

const GRAVITY = 20.0
const MAX_JUMP_HEIGHT = 1.0 # About the height of a block.
# To derive the formula for calculating jump speed, first solve
#    v_t = v_0 + a * t
# for the time at which you achieve maximum height, where a is the acceleration
# due to gravity and v_t = 0. This gives:
#    t = - v_0 / a
# Use t and the desired MAX_JUMP_HEIGHT to solve for v_0 (jump speed) in
#    s = s_0 + v_0 * t + (a * t^2) / 2
const JUMP_SPEED = sqrt(2 * GRAVITY * MAX_JUMP_HEIGHT)
const TERMINAL_VELOCITY = 50

const PLAYER_HEIGHT = 2

var vertexBuffer : GLuint
var indexBuffer: GLuint
var uvBuffer: GLuint


proc cube_vertices(x, y, z, n: float32): seq[float32] =
    ## Return the vertices of the cube at position x, y, z with size 2*n.
    @[
        x-n,y+n,z-n, x-n,y+n,z+n, x+n,y+n,z+n, x+n,y+n,z-n,  # top
        x-n,y-n,z-n, x+n,y-n,z-n, x+n,y-n,z+n, x-n,y-n,z+n,  # bottom
        x-n,y-n,z-n, x-n,y-n,z+n, x-n,y+n,z+n, x-n,y+n,z-n,  # left
        x+n,y-n,z+n, x+n,y-n,z-n, x+n,y+n,z-n, x+n,y+n,z+n,  # right
        x-n,y-n,z+n, x+n,y-n,z+n, x+n,y+n,z+n, x-n,y+n,z+n,  # front
        x+n,y-n,z-n, x-n,y-n,z-n, x-n,y+n,z-n, x+n,y+n,z-n  # back
    ]



proc tex_coord(x, y: int, n: float32 = 4): seq[float32] =
    ## Return the bounding vertices of the texture square.
    let m = 1'f32 / n
    let dx = x.float32 * m
    let dy = y.float32 * m
    return @[dx, dy, dx + m, dy, dx + m, dy + m, dx, dy + m]

type BlockTexture = ref object
    uv: seq[float32]
    offsetInUVBuffer: int

proc tex_coords(top, bottom, side: tuple[x, y: int]): BlockTexture =
    ## Return a list of the texture squares for the top, bottom and side.

    result.new()

    result.uv = tex_coord(top.x, top.y)
    result.uv.add(tex_coord(bottom.x, bottom.y))
    let side = tex_coord(side.x, side.y)
    result.uv.add(side)
    result.uv.add(side)
    result.uv.add(side)
    result.uv.add(side)

const TEXTURE_PATH = "texture.png"

let GRASS = tex_coords((1, 0), (0, 1), (0, 0))
let SAND = tex_coords((1, 1), (1, 1), (1, 1))
let BRICK = tex_coords((2, 0), (2, 0), (2, 0))
let STONE = tex_coords((2, 1), (2, 1), (2, 1))


proc createBuffers() =
    let gl = currentContext().gl
    vertexBuffer = gl.createBuffer()
    indexBuffer = gl.createBuffer()
    uvBuffer = gl.createBuffer()

    gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer)
    gl.bufferData(gl.ARRAY_BUFFER, cube_vertices(0, 0, 0, 0.5), gl.STATIC_DRAW)

    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer)
    let indexData = [0.GLubyte, 1, 2, 0, 2, 3, # top
                    4, 5, 6, 4, 6, 7,         # bottom
                    8, 9, 10, 8, 10, 11,      # left
                    12, 13, 14, 12, 14, 15,   # right
                    16, 17, 18, 16, 18, 19,   # front
                    20, 21, 22, 20, 22, 23    # back
                    ]
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, indexData, gl.STATIC_DRAW)

    var uvData = GRASS.uv
    SAND.offsetInUVBuffer = uvData.len * sizeof(GLfloat)
    uvData.add(SAND.uv)
    BRICK.offsetInUVBuffer = uvData.len * sizeof(GLfloat)
    uvData.add(BRICK.uv)
    STONE.offsetInUVBuffer = uvData.len * sizeof(GLfloat)
    uvData.add(STONE.uv)

    gl.bindBuffer(gl.ARRAY_BUFFER, uvBuffer)
    gl.bufferData(gl.ARRAY_BUFFER, uvData, gl.STATIC_DRAW)


let FACES = [
    [ 0.GLint, 1, 0],
    [ 0.GLint,-1, 0],
    [-1.GLint, 0, 0],
    [ 1.GLint, 0, 0],
    [ 0.GLint, 0, 1],
    [ 0.GLint, 0,-1],
]


proc normalize(position: Vector3): iVec3 =
    ##[ Accepts `position` of arbitrary precision and returns the block
    containing that position.

    Parameters
    ----------
    position : tuple of len 3

    Returns
    -------
    block_position : tuple of ints of len 3

    ]##
    return [round(position.x).GLint, round(position.y).GLint, round(position.z).GLint]


proc sectorize(position: iVec3): iVec3 =
    ##[ Returns a tuple representing the sector for the given `position`.

    Parameters
    ----------
    position : tuple of len 3

    Returns
    -------
    sector : tuple of len 3

    ]##
    result.x = GLint(position.x / SECTOR_SIZE)
    result.z = GLint(position.z / SECTOR_SIZE)

proc sectorize(position: Vector3): iVec3 = sectorize(normalize(position))


type Model = ref object
    # A Batch is a collection of vertex lists for batched rendering.
    batch: int

    # A TextureGroup manages an OpenGL texture.
    group: Image

    # A mapping from position to the texture of the block at that position.
    # This defines all the blocks that are currently in the world.
    world: Table[iVec3, BlockTexture]

    # Same mapping as `world` but only contains blocks that are shown.
    shown: Table[iVec3, BlockTexture]

    # Mapping from position to a pyglet `VertextList` for all shown blocks.
    shown_vertex_lists: Table[iVec3, int]

    # Mapping from sector to a list of positions inside that sector.
    sectors: Table[iVec3, Table[iVec3, bool]]

    # Simple function queue implementation. The queue is populated with
    # show_block_aux() and hide_block_aux() calls
    queue: SinglyLinkedList[proc()]

proc initialize(self: Model)

proc newModel(): Model =
        result.new()

        result.group = imageWithResource("texture.png")

        # A mapping from position to the texture of the block at that position.
        # This defines all the blocks that are currently in the world.
        result.world = initTable[iVec3, BlockTexture](256)

        # Same mapping as `world` but only contains blocks that are shown.
        result.shown = initTable[iVec3, BlockTexture](256)

        # Mapping from sector to a list of positions inside that sector.
        result.sectors = initTable[iVec3, Table[iVec3, bool]](256)

        result.initialize()

proc randint(a, b: int): int = random(b - a + 1) + a

proc add_block(self: Model, position: iVec3, texture: BlockTexture, immediate=true)

proc initialize(self: Model) =
        ## Initialize the world by placing all the blocks.

        let n = 80.GLint  # 1/2 width and height of world
        let y = 0.GLint  # initial y height
        for x in -n .. n:
            for z in -n .. n:
                # create a layer stone an grass everywhere.
                self.add_block([x, y - 2, z], GRASS, immediate=false)
                self.add_block([x, y - 3, z], STONE, immediate=false)
                if abs(x) == n or abs(z) == n:
                    # create outer walls.
                    for dy in -2 .. 2:
                        self.add_block([x, y + dy.GLint, z], STONE, immediate=false)

        # generate the hills randomly
        let o = n - 10
        for _ in 0 ..< 120:
            let a = randint(-o, o).GLint  # x position of the hill
            let b = randint(-o, o).GLint  # z position of the hill
            let c = -1.GLint # base of the hill
            let h = randint(1, 6).GLint  # height of the hill
            var s = randint(4, 8).GLint  # 2 * s is the side length of the hill
            const d = 1  # how quickly to taper off the hills
            let t = [GRASS, SAND, BRICK][random(3)]
            for y in c ..< c + h:
                for x in a - s .. a + s:
                    for z in b - s .. b + s:
                        if (x - a) ^ 2 + (z - b) ^ 2 > (s + 1) ^ 2:
                            continue
                        if (x - 0) ^ 2 + (z - 0) ^ 2 < 5 ^ 2:
                            continue
                        self.add_block([x, y, z], t, immediate=false)
                s -= d  # decrement side lenth so hills taper off

proc hit_test(self: Model, position: Vector3, vector: Vector3, max_distance: int = 8): tuple[ok: bool, bl, prev: iVec3] =
        ##[ Line of sight search from current position. If a block is
        intersected it is returned, along with the block previously in the line
        of sight. If no block is found, return None, None.

        Parameters
        ----------
        position : tuple of len 3
            The (x, y, z) position to check visibility from.
        vector : tuple of len 3
            The line of sight vector.
        max_distance : int
            How many blocks away to search for a hit.

        ]##
        let m = 8
        var p = position
        let dp = vector / float32(m)
        var previous : iVec3
        for i in 0 ..< max_distance * m:
            let key = normalize(p)
            if key != previous and key in self.world:
                result.ok = true
                result.bl = key
                result.prev = previous
                return
            previous = key
            p += dp

proc exposed(self: Model, position: iVec3): bool =
        ##[ Returns False is given `position` is surrounded on all 6 sides by
        blocks, True otherwise.

        ]##
        for f in FACES:
            if (f + position) notin self.world:
                return true
        return false

proc hide_block(self: Model, position: iVec3, immediate=true)
proc check_neighbors(self: Model, position: iVec3)

template excl(t: var Table[iVec3, bool], k: iVec3) = t.del(k)
template incl(t: var Table[iVec3, bool], k: iVec3) = t[k] = true

proc remove_block(self: Model, position: iVec3, immediate=true) =
        ##[ Remove the block at the given `position`.

        Parameters
        ----------
        position : tuple of len 3
            The (x, y, z) position of the block to remove.
        immediate : bool
            Whether or not to immediately remove block from canvas.

        ]##
        self.world.del(position)
        self.sectors[sectorize(position)].excl(position)
        if immediate or true:
            if position in self.shown:
                self.hide_block(position)
            self.check_neighbors(position)

template setdefault[K, V](t: var Table[K, V], k: K, d: V): var V =
    let kk = k
    if kk notin t: t[kk] = d
    t[kk]

proc show_block(self: Model, position: iVec3, immediate=true)

proc add_block(self: Model, position: iVec3, texture: BlockTexture, immediate=true) =
        ##[ Add a block with the given `texture` and `position` to the world.

        Parameters
        ----------
        position : tuple of len 3
            The (x, y, z) position of the block to add.
        texture : list of len 3
            The coordinates of the texture squares. Use `tex_coords()` to
            generate.
        immediate : bool
            Whether or not to draw the block immediately.

        ]##
        if position in self.world:
            self.remove_block(position, immediate)
        self.world[position] = texture
        self.sectors.setdefault(sectorize(position), initTable[iVec3, bool](256)).incl(position)
        if immediate or true:
            if self.exposed(position):
                self.show_block(position)
            self.check_neighbors(position)

proc check_neighbors(self: Model, position: iVec3) =
        ##[ Check all blocks surrounding `position` and ensure their visual
        state is current. This means hiding blocks that are not exposed and
        ensuring that all exposed blocks are shown. Usually used after a block
        is added or removed.

        ]##
        for f in FACES:
            let key = position + f
            if key notin self.world:
                continue
            if self.exposed(key):
                if key notin self.shown:
                    self.show_block(key)
            else:
                if key in self.shown:
                    self.hide_block(key)

proc show_block_aux(self: Model, position: iVec3, texture: BlockTexture)
proc enqueue(self: Model, f: proc())

proc show_block(self: Model, position: iVec3, immediate=true) =
        ##[ Show the block at the given `position`. This method assumes the
        block has already been added with add_block()

        Parameters
        ----------
        position : tuple of len 3
            The (x, y, z) position of the block to show.
        immediate : bool
            Whether or not to show the block immediately.

        ]##
        let texture = self.world[position]
        self.shown[position] = texture
        if immediate:
            self.show_block_aux(position, texture)
        else:
            self.enqueue(proc() = self.show_block_aux(position, texture))

proc show_block_aux(self: Model, position: iVec3, texture: BlockTexture) =
        ##[ Private implementation of the `show_block()` method.

        Parameters
        ----------
        position : tuple of len 3
            The (x, y, z) position of the block to show.
        texture : list of len 3
            The coordinates of the texture squares. Use `tex_coords()` to
            generate.

        ]##
        let vertex_data = cube_vertices(position.x.float32, position.y.float32, position.z.float32, 0.5)
        # create vertex list
        # FIXME Maybe `add_indexed()` should be used instead
        #self.shown_vertex_lists[position] = self.batch.add(24, GL_QUADS, self.group,
        #    ("v3f/static", vertex_data),
        #    ("t2f/static", texture.uv))

proc hide_block_aux(self: Model, position: iVec3) =
        ##[ Private implementation of the 'hide_block()` method.

        ]##
        #self.shown_vertex_lists.pop(position).delete()
        discard

proc hide_block(self: Model, position: iVec3, immediate=true) =
        ##[ Hide the block at the given `position`. Hiding does not remove the
        block from the world.

        Parameters
        ----------
        position : tuple of len 3
            The (x, y, z) position of the block to hide.
        immediate : bool
            Whether or not to immediately remove the block from the canvas.

        ]##
        self.shown.del(position)
        if immediate or true:
            self.hide_block_aux(position)
        else:
            self.enqueue(proc() = self.hide_block_aux(position))

proc show_sector(self: Model, sector: iVec3) =
        ##[ Ensure all blocks in the given sector that should be shown are
        drawn to the canvas.

        ]##
        for position, _ in self.sectors.getOrDefault(sector):
            if position notin self.shown and self.exposed(position):
                self.show_block(position, false)

proc hide_sector(self: Model, sector: iVec3) =
        ##[ Ensure all blocks in the given sector that should be hidden are
        removed from the canvas.

        ]##
        for position, _ in self.sectors.getOrDefault(sector):
            if position in self.shown:
                self.hide_block(position, false)

proc change_sectors(self: Model, before, after: iVec3) =
        ##[ Move from sector `before` to sector `after`. A sector is a
        contiguous x, y sub-region of world. Sectors are used to speed up
        world rendering.

        ]##
        var before_set = initTable[iVec3, bool]()
        var after_set = initTable[iVec3, bool]()
        let pad = 4.GLint
        for dx in -pad .. pad:
            for dy in [0.GLint]:  # xrange(-pad, pad + 1):
                for dz in -pad .. pad:
                    if dx ^ 2 + dy ^ 2 + dz ^ 2 > (pad + 1) ^ 2:
                        continue
                    before_set.incl([before.x + dx, before.y + dy, before.z + dz])
                    after_set.incl([after.x + dx, after.y + dy, after.z + dz])
        for k, _ in before_set:
            if k notin after_set:
                self.hide_sector(k)

        for k, _ in after_set:
            if k notin before_set:
                self.show_sector(k)

template isEmpty(L: SinglyLinkedList): bool = L.head.isNil

proc popFront[T](L: var SinglyLinkedList[T]): SinglyLinkedNode[T] =
    result = L.head
    L.head = L.head.next

proc append[T](L: var SinglyLinkedList[T]; n: SinglyLinkedNode[T]) =
    if not L.tail.isNil:
        L.tail.next = n
    L.tail = n

proc enqueue(self: Model, f: proc()) =
        ## Add `f` to the internal queue.
        self.queue.append(newSinglyLinkedNode(f))

proc dequeue(self: Model) =
        ## Pop the top function from the internal queue and call it.
        let f = self.queue.popFront().value
        f()

proc process_queue(self: Model) =
        #[ Process the entire queue while taking periodic breaks. This allows
        the game loop to run smoothly. The queue contains calls to
        show_block_aux() and hide_block_aux() so this method should be called if
        add_block() or remove_block() was called with immediate=False

        ]#
        let start = epochTime()
        while not self.queue.isEmpty and epochTime() - start < 1.0 / TICKS_PER_SEC:
            self.dequeue()

proc process_entire_queue(self: Model) =
        ## Process the entire queue with no breaks.
        while not self.queue.isEmpty:
            self.dequeue()

type GameView = ref object of SceneView
    exclusive: bool # Whether or not the window exclusively captures the mouse.
    flying: bool # When flying gravity has no effect and speed is increased.

    # Strafing is moving lateral to the direction you are facing,
    # e.g. moving to the left or right while continuing to face forward.
    #
    # First element is -1 when moving forward, 1 when moving back, and 0
    # otherwise. The second element is -1 when moving left, 1 when moving
    # right, and 0 otherwise.
    strafe: TVector[2, int]

    # Current (x, y, z) position in the world, specified with floats. Note
    # that, perhaps unlike in math class, the y-axis is the vertical axis.
    position: Vector3

    # First element is rotation of the player in the x-z plane (ground
    # plane) measured from the z-axis down. The second is the rotation
    # angle from the ground plane up. Rotation is in degrees.
    #
    # The vertical plane rotation ranges from -90 (looking straight down) to
    # 90 (looking straight up). The horizontal rotation range is unbounded.
    rotation: Vector2

    # Which sector the player is currently in.
    sector: iVec3 # = None

    dy: float32 # Velocity in the y (upward) direction.

    inventory: seq[BlockTexture] # A list of blocks the player can place. Hit num keys to cycle.

    blockInHand: BlockTexture # The current block the user can place. Hit num keys to cycle.

    model: Model

proc update(self: GameView, dt: float32)

method init(self: GameView, r: Rect) =
        procCall self.SceneView.init(r)

        # The crosshairs at the center of the screen.
        #self.reticle = nil

        # A list of blocks the player can place. Hit num keys to cycle.
        self.inventory = @[BRICK, GRASS, SAND]

        # The current block the user can place. Hit num keys to cycle.
        self.blockInHand = self.inventory[0]

        # Convenience list of num keys.
        #self.num_keys = [
        #    key._1, key._2, key._3, key._4, key._5,
        #    key._6, key._7, key._8, key._9, key._0]

        # Instance of the model that handles the world.
        self.model = newModel()

        # The label that is displayed in the top left of the canvas.
        #self.label = pyglet.text.Label('', font_name='Arial', font_size=18,
        #    x=10, y=self.height - 10, anchor_x='left', anchor_y='top',
        #    color=(0, 0, 0, 255))

        # This call schedules the `update()` method to be called
        # TICKS_PER_SEC. This is the main game event loop.


#        pyglet.clock.schedule_interval(self.update, 1.0 / TICKS_PER_SEC)

#[
    def set_exclusive_mouse(self, exclusive):
        """ If `exclusive` is True, the game will capture the mouse, if False
        the game will ignore the mouse.

        """
        super(Window, self).set_exclusive_mouse(exclusive)
        self.exclusive = exclusive
]#
proc get_sight_vector(self: GameView): Vector3 =
        ##[ Returns the current line of sight vector indicating the direction
        the player is looking.

        ]##
        let x = self.rotation.x
        let y = self.rotation.y
        # y ranges from -90 to 90, or -pi/2 to pi/2, so m ranges from 0 to 1 and
        # is 1 when looking ahead parallel to the ground and 0 when looking
        # straight up or down.
        let m = cos(degToRad(y))
        # dy ranges from -1 to 1 and is -1 when looking straight down and 1 when
        # looking straight up.
        result.y = sin(degToRad(y))
        result.x = cos(degToRad(x - 90)) * m
        result.z = sin(degToRad(x - 90)) * m

proc get_motion_vector(self: GameView): Vector3 =
        ##[ Returns the current motion vector indicating the velocity of the
        player.

        Returns
        -------
        vector : tuple of len 3
            Tuple containing the velocity in x, y, and z respectively.

        ]##
        if self.strafe.x != 0 or self.strafe.y != 0:
            let strafe = radToDeg(arctan2(self.strafe.x.float, self.strafe.y.float))
            let y_angle = degToRad(self.rotation.y)
            let x_angle = degToRad(self.rotation.x + strafe)
            if self.flying:
                var m = cos(y_angle)
                result.y = sin(y_angle)
                if self.strafe.y != 0:
                    # Moving left or right.
                    result.y = 0.0
                    m = 1
                if self.strafe.x > 0:
                    # Moving backwards.
                    result.y *= -1
                # When you are flying up or down, you have less left and right
                # motion.
                result.x = cos(x_angle) * m
                result.z = sin(x_angle) * m
            else:
                result.y = 0.0
                result.x = cos(x_angle)
                result.z = sin(x_angle)

proc update_aux(self: GameView, dt: float32)

proc update(self: GameView, dt: float32) =
        ##[ This method is scheduled to be called repeatedly by the pyglet
        clock.

        Parameters
        ----------
        dt : float
            The change in time since the last call.

        ]##
        self.model.process_queue()
        let sector = sectorize(self.position)
        if sector != self.sector:
            self.model.change_sectors(self.sector, sector)
            #if self.sector is None:
            #block:
            #    self.model.process_entire_queue()
            self.sector = sector
        let m = 8
        let mdt = min(dt, 0.2)
        for _ in 0 ..< m:
            self.update_aux(mdt / m.float)

proc collide(self: GameView, position: Vector3, height: GLint): Vector3

proc update_aux(self: GameView, dt: float32) =
        ##[ Private implementation of the `update()` method. This is where most
        of the motion logic lives, along with gravity and collision detection.

        Parameters
        ----------
        dt : float
            The change in time since the last call.

        ]##
        # walking
        let speed = if self.flying: FLYING_SPEED else: WALKING_SPEED
        let d = dt * speed.float32 # distance covered this tick.
        var mv = self.get_motion_vector()
        # New position in space, before accounting for gravity.
        mv *= d
        # gravity
        if not self.flying:
            # Update your vertical speed: if you are falling, speed up until you
            # hit terminal velocity; if you are jumping, slow down until you
            # start falling.
            self.dy -= dt * GRAVITY
            self.dy = max(self.dy, -TERMINAL_VELOCITY)
            mv.y += self.dy * dt
        # collisions
        self.position = self.collide(self.position + mv, PLAYER_HEIGHT)
        self.camera.node.translation = self.position

proc collide(self: GameView, position: Vector3, height: GLint): Vector3 =
        ##[ Checks to see if the player at the given `position` and `height`
        is colliding with any blocks in the world.

        Parameters
        ----------
        position : tuple of len 3
            The (x, y, z) position to check for collisions at.
        height : int or float
            The height of the player.

        Returns
        -------
        position : tuple of len 3
            The new position of the player taking into account collisions.

        ]##
        # How much overlap with a dimension of a surrounding block you need to
        # have to count as a collision. If 0, touching terrain at all counts as
        # a collision. If .49, you sink into the ground, as if walking through
        # tall grass. If >= .5, you'll fall through the ground.
        let pad = 0.25
        result = position
        let np = normalize(position)
        for face in FACES:  # check all surrounding blocks
            for i in 0 .. 2:  # check each dimension independently
                if face[i] == 0:
                    continue
                # How much overlap you have with this dimension.
                let d = (result[i] - np[i].Coord) * face[i].Coord
                if d < pad:
                    continue
                for dy in 0 ..< height:  # check each height
                    var op = np
                    op.y -= dy
                    op[i] += face[i]
                    if op notin self.model.world:
                        continue
                    result[i] -= (d - pad) * face[i].float
                    if face == [0.GLint, -1, 0] or face == [0.GLint, 1, 0]:
                        # You are colliding with the ground or ceiling, so stop
                        # falling / rising.
                        self.dy = 0
                    break

#[
proc on_mouse_press(self: GameView, x, y: float32, button, modifiers):
        """ Called when a mouse button is pressed. See pyglet docs for button
        amd modifier mappings.

        Parameters
        ----------
        x, y : int
            The coordinates of the mouse click. Always center of the screen if
            the mouse is captured.
        button : int
            Number representing mouse button that was clicked. 1 = left button,
            4 = right button.
        modifiers : int
            Number representing any modifying keys that were pressed when the
            mouse button was clicked.

        """
        if self.exclusive:
            vector = self.get_sight_vector()
            block, previous = self.model.hit_test(self.position, vector)
            if (button == mouse.RIGHT) or \
                    ((button == mouse.LEFT) and (modifiers & key.MOD_CTRL)):
                # ON OSX, control + left click = right click.
                if previous:
                    self.model.add_block(previous, self.block)
            elif button == pyglet.window.mouse.LEFT and block:
                texture = self.model.world[block]
                if texture != STONE:
                    self.model.remove_block(block)
        else:
            self.set_exclusive_mouse(True)
]#

var lastPos: Point

method onInterceptTouchEv*(v: GameView, e: var Event): bool =
    # echo v.name(), " onInterceptTouchEv ",e.localPosition
    result = true
    echo "intercepts"
    discard

method onTouchEv(self: GameView, e: var Event): bool =
        ##[ Called when the player moves the mouse.

        Parameters
        ----------
        x, y : int
            The coordinates of the mouse click. Always center of the screen if
            the mouse is captured.
        dx, dy : float
            The movement of the mouse.

        ]##
        discard procCall self.SceneView.onTouchEv(e)
        result = true
        if self.exclusive or true:
            if lastPos != zeroPoint:
                let m = 0.15
                var x = self.rotation[0]
                var y = self.rotation[1]
                let d = e.localPosition - lastPos
                x += d.x * m
                y += d.y * m
                y = max(-90, min(90, y))
                self.rotation = [x, y]
                self.camera.node.rotation = aroundX(y) * aroundY(x)

        lastPos = e.localPosition
        if e.buttonState == bsUp:
            lastPos = zeroPoint

method acceptsFirstResponder(self: GameView): bool = true

method onKeyDown(self: GameView, e: var Event): bool =
        ##[ Called when the player presses a key. See pyglet docs for key
        mappings.

        Parameters
        ----------
        symbol : int
            Number representing the key that was pressed.
        modifiers : int
            Number representing any modifying keys that were pressed.

        ]##
        if e.repeat: return

        case e.keyCode
        of VirtualKey.W:
            self.strafe[0] -= 1
        of VirtualKey.S:
            self.strafe[0] += 1
        of VirtualKey.A:
            self.strafe[1] -= 1
        of VirtualKey.D:
            self.strafe[1] += 1
        of VirtualKey.Space:
            if self.dy == 0:
                self.dy = JUMP_SPEED
        of VirtualKey.Escape:
            discard # self.set_exclusive_mouse(False)
        of VirtualKey.Tab:
            self.flying = not self.flying
        else:
            discard
        #[elif symbol in self.num_keys:
            index = (symbol - self.num_keys[0]) % len(self.inventory)
            self.block = self.inventory[index]
        ]#

method onKeyUp(self: GameView, e: var Event): bool =
        ##[ Called when the player releases a key. See pyglet docs for key
        mappings.

        Parameters
        ----------
        symbol : int
            Number representing the key that was pressed.
        modifiers : int
            Number representing any modifying keys that were pressed.

        ]##
        if e.repeat: return
        case e.keyCode
        of VirtualKey.W:
            self.strafe[0] += 1
        of VirtualKey.S:
            self.strafe[0] -= 1
        of VirtualKey.A:
            self.strafe[1] += 1
        of VirtualKey.D:
            self.strafe[1] -= 1
        else:
            discard

#[
    def on_resize(self, width, height):
        """ Called when the window is resized to a new `width` and `height`.

        """
        # label
        self.label.y = height - 10
        # reticle
        if self.reticle:
            self.reticle.delete()
        x, y = self.width / 2, self.height / 2
        n = 10
        self.reticle = pyglet.graphics.vertex_list(4,
            ('v2i', (x - n, y, x + n, y, x, y - n, x, y + n))
        )

    def set_2d(self):
        """ Configure OpenGL to draw in 2d.

        """
        width, height = self.get_size()
        glDisable(GL_DEPTH_TEST)
        glViewport(0, 0, width, height)
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        glOrtho(0, width, 0, height, -1, 1)
        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()

    def set_3d(self):
        """ Configure OpenGL to draw in 3d.

        """
        width, height = self.get_size()
        glEnable(GL_DEPTH_TEST)
        glViewport(0, 0, width, height)
        glMatrixMode(GL_PROJECTION)
        glLoadIdentity()
        gluPerspective(65.0, width / float(height), 0.1, 60.0)
        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()
        x, y = self.rotation
        glRotatef(x, 0, 1, 0)
        glRotatef(-y, math.cos(math.radians(x)), 0, math.sin(math.radians(x)))
        x, y, z = self.position
        glTranslatef(-x, -y, -z)
]#
method draw(self: GameView, r: Rect) =
        procCall self.SceneView.draw(r)
        ## Called by pyglet to draw the canvas.
#        self.clear()
#        self.set_3d()
#        glColor3d(1, 1, 1)
        #self.model.batch.draw()
#        self.draw_focused_block()
#        self.set_2d()
#        self.draw_reticle()
#[
    def draw_focused_block(self):
        """ Draw black edges around the block that is currently under the
        crosshairs.

        """
        vector = self.get_sight_vector()
        block = self.model.hit_test(self.position, vector)[0]
        if block:
            x, y, z = block
            vertex_data = cube_vertices(x, y, z, 0.51)
            glColor3d(0, 0, 0)
            glPolygonMode(GL_FRONT_AND_BACK, GL_LINE)
            pyglet.graphics.draw(24, GL_QUADS, ('v3f/static', vertex_data))
            glPolygonMode(GL_FRONT_AND_BACK, GL_FILL)

    def draw_reticle(self):
        """ Draw the crosshairs in the center of the screen.

        """
        glColor3d(0, 0, 0)
        self.reticle.draw(GL_LINES)
]#


proc setup() =
    ## Basic OpenGL configuration.

    # Set the color of "clear", i.e. the sky, in rgba.
    glClearColor(0.5, 0.69, 1.0, 1)
    # Enable culling (not rendering) of back-facing facets -- facets that aren't
    # visible to you.
    glEnable(GL_CULL_FACE)
    # Set the texture minification/magnification function to GL_NEAREST (nearest
    # in Manhattan distance) to the specified texture coordinates. GL_NEAREST
    # "is generally faster than GL_LINEAR, but it can produce textured images
    # with sharper edges because the transition between texture elements is not
    # as smooth."
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)

var shader : ProgramRef

let vs = """
attribute vec4 aPosition;
attribute vec2 aTexCoord;

uniform mat4 uModelViewProjectionMatrix;
uniform ivec3 uPosOffset;

varying vec2 vTexCoord;

void main() {
    vTexCoord = aTexCoord;
    vec4 p = aPosition;
    p.xyz += vec3(uPosOffset);
    gl_Position = uModelViewProjectionMatrix * p;
}
"""

let fs = """
#ifdef GL_ES
#extension GL_OES_standard_derivatives : enable
precision mediump float;
#endif

uniform sampler2D texUnit;
varying vec2 vTexCoord;

void main() {
    vec2 uv = vTexCoord;
    uv.y = 1.0 - uv.y;
    gl_FragColor = texture2D(texUnit, uv);
}
"""

proc drawModel(m: Model) =
    let c = currentContext()
    let gl = c.gl
    if shader == invalidProgram:
        createBuffers()
        shader = gl.newShaderProgram(vs, fs, [(0.GLuint, "aPosition"), (1.GLuint, "aTexCoord")])
    gl.useProgram(shader)
    gl.uniformMatrix4fv(gl.getUniformLocation(shader, "uModelViewProjectionMatrix"), false, c.transform)
    gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer)
    gl.vertexAttribPointer(0, 3, cGL_FLOAT, true, 0, 0)
    gl.enableVertexAttribArray(1)
    gl.bindBuffer(gl.ARRAY_BUFFER, uvBuffer)

    var texCoords: array[4, GLfloat]
    let t = m.group.getTextureQuad(gl, texCoords)

    gl.activeTexture(gl.TEXTURE0)
    gl.uniform1i(gl.getUniformLocation(shader, "texUnit"), 0)
    gl.bindTexture(gl.TEXTURE_2D, t)

    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer)

    gl.enable(gl.DEPTH_TEST)

    let loc = gl.getUniformLocation(shader, "uPosOffset")

    for k, v in m.shown:
        let kk = k
        gl.uniform3iv(loc, kk)
        gl.vertexAttribPointer(1, 2, cGL_FLOAT, false, 0, v.offsetInUVBuffer)
        gl.drawElements(gl.TRIANGLES, 6 * 6, gl.UNSIGNED_BYTE)

    gl.disable(gl.DEPTH_TEST)

    when defined(js):
        {.emit: """
        `gl`.bindBuffer(`gl`.ELEMENT_ARRAY_BUFFER, null);
        `gl`.bindBuffer(`gl`.ARRAY_BUFFER, null);
        """.}
    else:
        gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0)
        gl.bindBuffer(gl.ARRAY_BUFFER, 0)

import rod.edit_view

proc startApplication() =
    var mainWindow: Window
    when defined(ios) or defined(android):
        mainWindow = newFullscreenWindow()
    else:
        mainWindow = newWindow(newRect(40, 40, 800, 600))
    var mainView = GameView.new(mainWindow.bounds)
    mainView.autoresizingMask = {afFlexibleWidth, afFlexibleHeight}
    mainWindow.addSubview(mainView)

    mainView.rootNode = newNode()
    let cn = mainView.rootNode.newChild("camera")
    let cam = cn.component(Camera) # Create camera
    cn.translation = newVector3(0, 0, 5)
    cam.zNear = 0.1
    cam.zFar = 500
    let worldNode = mainView.rootNode.newChild("world")
    worldNode.setComponent "World", newComponentWithDrawProc(proc() =
        mainView.model.drawModel()
    )

    #discard startEditingNodeInView(mainView.rootNode, mainView)

    let a = newAnimation()
    a.numberOfLoops = -1
    a.loopDuration = 1

    var lastTime = epochTime()

    a.onAnimate = proc(p: float) =
        let t = epochTime()
        mainView.update(t - lastTime)
        lastTime = t

    mainWindow.addAnimation(a)


    # Hide the mouse cursor and prevent the mouse from leaving the window.
#    window.set_exclusive_mouse(True)
#    setup()
#    pyglet.app.run()

when defined js:
    import dom
    dom.window.onload = proc (e: dom.Event) =
        startApplication()
else:
    try:
        startApplication()
        runUntilQuit()
    except:
        logi "Exception caught: ", getCurrentExceptionMsg()
        logi getCurrentException().getStackTrace()
        quit 1
