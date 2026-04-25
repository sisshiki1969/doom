# frozen_string_literal: true

module Doom
  module Game
    # Player movement and vertical physics, extracted from the Gosu window
    # so it can be unit-tested without a graphics stack.
    #
    # Tracks the player's feet position (floor_z) and vertical velocity (momz)
    # in DOOM map units, matching Chocolate Doom's P_ZMovement semantics:
    # GRAVITY=1 unit/tic^2, falls clamp to floor, viewheight squat on landing.
    class PlayerPhysics
      PLAYER_RADIUS = 16.0

      MAX_STEP_UP = 24
      MIN_HEADROOM = 56

      GRAVITY = 1.0
      INITIAL_FALL_MOMZ = -2.0       # First-tic kick when momz==0 (P_ZMovement uses -GRAVITY*2)
      FALL_IMPACT_THRESHOLD = -8.0   # momz < -GRAVITY*8 triggers viewheight squat

      # Solid thing types with their collision radii (from mobjinfo[] MF_SOLID).
      SOLID_THING_RADIUS = {
        9 => 20, 65 => 20, 66 => 20, 67 => 20, 68 => 20, # Shotgun Guy variants
        3004 => 20, 84 => 20,                            # Zombieman
        3001 => 20,                                       # Imp
        3002 => 30, 58 => 30,                             # Demon, Spectre
        3003 => 24, 69 => 24,                             # Baron, Hell Knight
        3006 => 16,                                       # Lost Soul
        3005 => 31,                                       # Cacodemon
        16 => 40,                                         # Cyberdemon
        7 => 128,                                         # Spider Mastermind
        64 => 20,                                         # Archvile
        71 => 31,                                         # Pain Elemental
        2035 => 10,                                       # Barrel
        2028 => 16,                                       # Tall lamp
        48 => 16, 30 => 16, 32 => 16,                     # Tech column, green/red pillars
        31 => 16, 33 => 16, 36 => 16,                     # Short pillars
        41 => 16, 43 => 16,                               # Evil eye, burnt tree
        54 => 32,                                         # Brown tree
        44 => 16, 45 => 16, 46 => 16,                     # Tall torches
        55 => 16, 56 => 16, 57 => 16,                     # Short torches
        47 => 16, 70 => 16,                               # Stubs
        85 => 16, 86 => 16,                               # Tall tech lamps
        2046 => 16,                                       # Burning barrel
      }.freeze

      attr_reader :floor_z, :momz
      attr_writer :skill_hidden, :item_pickup, :combat

      def initialize(map, player_state)
        @map = map
        @player_state = player_state
        @floor_z = nil
        @momz = 0.0
        @skill_hidden = {}
        @item_pickup = nil
        @combat = nil
      end

      def reset
        @floor_z = nil
        @momz = 0.0
      end

      # Eye position used by the renderer: feet + viewheight + view-bob.
      # Returns nil before the first settle_at.
      def eye_z
        return nil unless @floor_z
        if @player_state
          @floor_z + @player_state.viewheight + @player_state.view_bob_offset
        else
          @floor_z + PlayerState::VIEWHEIGHT
        end
      end

      # Bring the player onto the floor at (x, y) after a horizontal move.
      # Snaps up for step-up (gated to <= MAX_STEP_UP by valid_move?), leaves
      # @floor_z alone for step-down so per-tic gravity can drop the player.
      def settle_at(x, y)
        sector = @map.sector_at(x, y)
        return unless sector

        new_floor = sector.floor_height

        if @player_state
          @floor_z ||= new_floor
          if new_floor > @floor_z
            step = new_floor - @floor_z
            @player_state.notify_step(step) if step.abs <= MAX_STEP_UP
            @floor_z = new_floor
            @momz = 0.0
          end
        else
          @floor_z = new_floor
        end
      end

      # Per-tic vertical movement. Mutates @floor_z and @momz; calls
      # player_state.notify_step / apply_fall_impact as needed.
      def step(x, y)
        return unless @player_state && @floor_z

        sector = @map.sector_at(x, y)
        return unless sector
        ground = sector.floor_height

        if @floor_z > ground
          @momz = (@momz == 0.0 ? INITIAL_FALL_MOMZ : @momz - GRAVITY)
          @floor_z += @momz
          if @floor_z <= ground
            impact_momz = @momz
            @floor_z = ground
            @momz = 0.0
            @player_state.apply_fall_impact(impact_momz) if impact_momz < FALL_IMPACT_THRESHOLD
          end
        elsif @floor_z < ground
          # Floor rose under player (lift, raising sector)
          step_amount = ground - @floor_z
          @player_state.notify_step(step_amount) if step_amount.abs <= MAX_STEP_UP
          @floor_z = ground
          @momz = 0.0
        end
      end

      # When valid_move? fails, find the nearest blocking wall and return a
      # slide vector projected along it. Returns nil if no wall blocks.
      def compute_slide(px, py, dx, dy)
        best_wall = nil
        best_dist = Float::INFINITY

        @map.linedefs.each do |linedef|
          v1 = @map.vertices[linedef.v1]
          v2 = @map.vertices[linedef.v2]

          next unless line_circle_intersect?(v1.x, v1.y, v2.x, v2.y, px + dx, py + dy, PLAYER_RADIUS)
          next unless linedef_blocks?(linedef, px + dx, py + dy) ||
                      crosses_blocking_linedef?(px, py, px + dx, py + dy, linedef)

          dist = point_to_line_distance(px, py, v1.x, v1.y, v2.x, v2.y)
          if dist < best_dist
            best_dist = dist
            best_wall = linedef
          end
        end

        return nil unless best_wall

        v1 = @map.vertices[best_wall.v1]
        v2 = @map.vertices[best_wall.v2]
        wall_dx = (v2.x - v1.x).to_f
        wall_dy = (v2.y - v1.y).to_f
        wall_len = Math.sqrt(wall_dx * wall_dx + wall_dy * wall_dy)
        return nil if wall_len == 0

        wall_dx /= wall_len
        wall_dy /= wall_len
        dot = dx * wall_dx + dy * wall_dy
        [dot * wall_dx, dot * wall_dy]
      end

      # True if the player can occupy (new_x, new_y). Step-up is capped at
      # MAX_STEP_UP from the player's current floor; step-down is unlimited.
      def valid_move?(old_x, old_y, new_x, new_y)
        sector = @map.sector_at(new_x, new_y)
        return false unless sector

        current_floor = @floor_z || sector.floor_height
        return false if sector.floor_height - current_floor > MAX_STEP_UP

        @map.linedefs.each do |linedef|
          return false if linedef_blocks?(linedef, new_x, new_y)
          return false if crosses_blocking_linedef?(old_x, old_y, new_x, new_y, linedef)
        end

        return false if collides_with_solid_thing?(new_x, new_y)

        true
      end

      private

      def crosses_blocking_linedef?(x1, y1, x2, y2, linedef)
        v1 = @map.vertices[linedef.v1]
        v2 = @map.vertices[linedef.v2]

        if linedef.sidedef_left == 0xFFFF
          return segments_intersect?(x1, y1, x2, y2, v1.x, v1.y, v2.x, v2.y)
        end

        if (linedef.flags & 0x0001) != 0  # ML_BLOCKING
          return segments_intersect?(x1, y1, x2, y2, v1.x, v1.y, v2.x, v2.y)
        end

        front_sector = sector_for_side(linedef.sidedef_right)
        back_sector = sector_for_side(linedef.sidedef_left)

        min_ceiling = [front_sector.ceiling_height, back_sector.ceiling_height].min
        max_floor = [front_sector.floor_height, back_sector.floor_height].max
        current_floor = @floor_z || front_sector.floor_height
        step_up = max_floor - current_floor

        return false if step_up <= MAX_STEP_UP && (min_ceiling - max_floor) >= MIN_HEADROOM

        segments_intersect?(x1, y1, x2, y2, v1.x, v1.y, v2.x, v2.y)
      end

      def linedef_blocks?(linedef, x, y)
        v1 = @map.vertices[linedef.v1]
        v2 = @map.vertices[linedef.v2]

        return false unless line_circle_intersect?(v1.x, v1.y, v2.x, v2.y, x, y, PLAYER_RADIUS)

        return true if linedef.sidedef_left == 0xFFFF

        # ML_BLOCKING on two-sided lines is handled by crosses_blocking_linedef?
        # (proximity check would block the player when standing near, not just crossing).

        front_sector = sector_for_side(linedef.sidedef_right)
        back_sector = sector_for_side(linedef.sidedef_left)

        min_ceiling = [front_sector.ceiling_height, back_sector.ceiling_height].min
        max_floor = [front_sector.floor_height, back_sector.floor_height].max
        current_floor = @floor_z || front_sector.floor_height
        step_up = max_floor - current_floor

        step_up > MAX_STEP_UP || (min_ceiling - max_floor) < MIN_HEADROOM
      end

      def collides_with_solid_thing?(x, y)
        picked = @item_pickup&.picked_up
        @map.things.each_with_index do |thing, idx|
          next if @skill_hidden[idx]
          next if picked && picked[idx]
          next if @combat && @combat.dead?(idx)
          thing_radius = SOLID_THING_RADIUS[thing.type]
          next unless thing_radius

          dx = x - thing.x
          dy = y - thing.y
          min_dist = PLAYER_RADIUS + thing_radius
          return true if dx * dx + dy * dy < min_dist * min_dist
        end
        false
      end

      def sector_for_side(side_idx)
        @map.sectors[@map.sidedefs[side_idx].sector]
      end

      def segments_intersect?(ax1, ay1, ax2, ay2, bx1, by1, bx2, by2)
        d1x = ax2 - ax1
        d1y = ay2 - ay1
        d2x = bx2 - bx1
        d2y = by2 - by1

        denom = d1x * d2y - d1y * d2x
        return false if denom.abs < 0.001

        dx = bx1 - ax1
        dy = by1 - ay1

        t = (dx * d2y - dy * d2x).to_f / denom
        u = (dx * d1y - dy * d1x).to_f / denom

        t > 0.0 && t < 1.0 && u >= 0.0 && u <= 1.0
      end

      def point_to_line_distance(px, py, x1, y1, x2, y2)
        dx = px - x1
        dy = py - y1
        line_dx = x2 - x1
        line_dy = y2 - y1
        line_len_sq = line_dx * line_dx + line_dy * line_dy
        return Math.sqrt(dx * dx + dy * dy) if line_len_sq == 0

        t = ((dx * line_dx) + (dy * line_dy)) / line_len_sq
        t = [[t, 0.0].max, 1.0].min
        closest_x = x1 + t * line_dx
        closest_y = y1 + t * line_dy
        Math.sqrt((px - closest_x)**2 + (py - closest_y)**2)
      end

      def line_circle_intersect?(x1, y1, x2, y2, cx, cy, radius)
        dx = cx - x1
        dy = cy - y1
        line_dx = x2 - x1
        line_dy = y2 - y1
        line_len_sq = line_dx * line_dx + line_dy * line_dy
        return false if line_len_sq == 0

        t = ((dx * line_dx) + (dy * line_dy)).to_f / line_len_sq
        t = [[t, 0.0].max, 1.0].min

        closest_x = x1 + t * line_dx
        closest_y = y1 + t * line_dy
        dist_x = cx - closest_x
        dist_y = cy - closest_y
        dist_sq = dist_x * dist_x + dist_y * dist_y

        dist_sq < radius * radius
      end
    end
  end
end
