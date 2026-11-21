package com.yashasvi.hackathon.fogops.console;

import com.yashasvi.hackathon.fogops.api.ApiException;
import com.yashasvi.hackathon.fogops.api.Times;
import org.springframework.http.HttpStatus;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.Map;

/** Read models behind the OCC console (no writes). Same paths and shapes as the original FastAPI. */
@RestController
@RequestMapping("/api")
public class ConsoleController {

    private final ConsoleService service;

    public ConsoleController(ConsoleService service) {
        this.service = service;
    }

    @GetMapping("/deadlines")
    public Map<String, Object> deadlines(@RequestParam("case_id") int caseId,
                                         @RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return service.deadlines(caseId, scenarioId);
    }

    @GetMapping("/flights/{flightId}/detail")
    public Map<String, Object> flightDetail(@PathVariable int flightId, @RequestParam("case_id") int caseId,
                                            @RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return service.flightDetail(flightId, caseId, scenarioId);
    }

    @GetMapping("/briefing")
    public Map<String, Object> briefing(@RequestParam("case_id") int caseId,
                                        @RequestParam(value = "scenario_id", required = false) Integer scenarioId,
                                        @RequestParam(value = "since", required = false) String since,
                                        @RequestParam(defaultValue = "12") int limit) {
        if (limit < 1 || limit > 50) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "limit must be between 1 and 50");
        }
        return service.briefing(caseId, scenarioId, Times.parse("since", since), limit);
    }

    @GetMapping("/ask/questions")
    public Map<String, Object> askQuestions(@RequestParam(value = "case_id", required = false) Integer caseId,
                                            @RequestParam(value = "scenario_id", required = false) Integer scenarioId) {
        return service.askQuestions(caseId, scenarioId);
    }
}
