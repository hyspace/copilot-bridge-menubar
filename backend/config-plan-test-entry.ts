// Test-only source entry; production calls the same planner from the bundled service.
import { runConfigPlanner } from "./codex-config-plan";
await runConfigPlanner();
