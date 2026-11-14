def crystal_body(active_ability, move_type, damage):
    if active_ability != 16 or damage <= 0:
        return damage
    if move_type == 11:
        return 0
    if move_type == 10:
        return damage * 2
    return max(1, damage // 2)

def test_water_is_zero_not_heal():
    assert crystal_body(16, 11, 73) == 0

def test_fire_is_double():
    assert crystal_body(16, 10, 73) == 146

def test_other_damage_is_half_with_floor():
    assert crystal_body(16, 12, 73) == 36
    assert crystal_body(16, 12, 1) == 1

def test_suppression_bypasses():
    assert crystal_body(0, 11, 73) == 73

def test_status_damage_path_bypasses():
    assert crystal_body(16, 11, 0) == 0
