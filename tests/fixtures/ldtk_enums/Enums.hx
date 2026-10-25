// Simple enums are imported, parametered ones skipped
enum Weapon {
	Sword;
	Bow; // a comment
	/* Hidden; */
}

enum Effect {
	Burn(time:Float);
	Freeze;
}
