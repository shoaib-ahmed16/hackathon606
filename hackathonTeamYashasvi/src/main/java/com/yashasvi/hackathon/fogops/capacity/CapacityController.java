package com.yashasvi.hackathon.fogops.capacity;

import com.fasterxml.jackson.databind.JsonNode;
import com.yashasvi.hackathon.fogops.api.Times;
import com.yashasvi.hackathon.fogops.auth.FogUser;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/**
 * Airport capacity (WP-4). Any signed-in user can read; only OCC or ADMIN can state an assumption. Nothing here approves
 * or executes a diversion: the assessment says whether the airport could take the flight and why, a person decides.
 */
@RestController
@RequestMapping("/api/airports")
public class CapacityController {

    private final CapacityService svc;

    public CapacityController(CapacityService svc) {
        this.svc = svc;
    }

    @GetMapping("/capacity")
    public List<Map<String, Object>> overview(@RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return svc.overview(svc.scenario(scenarioId));
    }

    /** The same what-if across all alternates, roomiest first. */
    @GetMapping("/capacity/compare")
    public List<Map<String, Object>> compare(@RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                             @RequestParam(value = "flight_id", required = false) Long flightId,
                                             @RequestParam(value = "extra", required = false) Integer extra,
                                             @RequestParam(value = "delay_min", required = false) Integer delayMin,
                                             @RequestParam(value = "arrival", required = false) String arrival,
                                             @RequestParam(value = "window_h", required = false) Integer windowH) {
        return svc.compare(svc.scenario(scenarioId), Times.parse("arrival", arrival),
                CapacityRules.bounded(extra, "extra", 0, 50, 0), flightId,
                CapacityRules.bounded(delayMin, "delay_min", 0, 1440, 0), CapacityRules.bounded(windowH, "window_h", 1, 48, 12));
    }

    @GetMapping("/{iata}/capacity")
    public Map<String, Object> detail(@PathVariable String iata,
                                      @RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                      @RequestParam(value = "window_h", required = false) Integer windowH) {
        return svc.detail(svc.scenario(scenarioId), CapacityRules.iata(iata), CapacityRules.bounded(windowH, "window_h", 1, 48, 24));
    }

    /** Can this airport take the flight (and N more, delayed by M minutes)? Read-only: nothing is stored. */
    @GetMapping("/{iata}/capacity/assess")
    public JsonNode assess(@PathVariable String iata,
                           @RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                           @RequestParam(value = "flight_id", required = false) Long flightId,
                           @RequestParam(value = "extra", required = false) Integer extra,
                           @RequestParam(value = "delay_min", required = false) Integer delayMin,
                           @RequestParam(value = "arrival", required = false) String arrival,
                           @RequestParam(value = "window_h", required = false) Integer windowH) {
        return svc.assessment(svc.scenario(scenarioId), CapacityRules.iata(iata), Times.parse("arrival", arrival),
                CapacityRules.bounded(extra, "extra", 0, 50, 0), flightId,
                CapacityRules.bounded(delayMin, "delay_min", 0, 1440, 0), CapacityRules.bounded(windowH, "window_h", 1, 48, 12));
    }

    @PutMapping("/{iata}/capacity")
    public Map<String, Object> set(@PathVariable String iata, @RequestBody(required = false) Map<String, Object> body,
                                   @AuthenticationPrincipal FogUser u) {
        CapacityRules.requireWriter(u.role());               // 403 before anything else
        String code = CapacityRules.iata(iata);
        CapacityRules.Setting s = CapacityRules.parse(body);   // 422 with a string detail
        return svc.setCapacity(u.userId(), svc.scenario(null), code, s);
    }
}
