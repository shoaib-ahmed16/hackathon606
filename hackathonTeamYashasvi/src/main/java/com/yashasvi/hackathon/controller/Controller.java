package com.yashasvi.hackathon.controller;

import static com.yashasvi.hackathon.config.SecurityConstants.*;
import com.yashasvi.hackathon.config.JwtTokenGeneratorFilter;
import com.yashasvi.hackathon.domain.UsersDetails;
import com.yashasvi.hackathon.dto.Constants;
import com.yashasvi.hackathon.dto.LoginBean;
import com.yashasvi.hackathon.dto.LoginResponse;
import com.yashasvi.hackathon.services.UsersDetailsService;
import com.yashasvi.hackathon.utils.Response;
import jakarta.annotation.Resource;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.AuthenticationException;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.web.bind.annotation.*;

import java.util.List;

@Slf4j
@RestController
public class Controller {

    @Autowired
    private UserDetailsService userService;

    @Autowired
    private AuthenticationManager authManager;


    @Autowired
    private PasswordEncoder passwordEncoder;

    @Autowired
    private JwtTokenGeneratorFilter jwtTokenGeneratorFilter;

    @Autowired
    @Resource(name = "usersDetailsService")
    private UsersDetailsService eleMarDetService;

    @GetMapping(HELLO)
    @ResponseStatus(HttpStatus.OK)
   public String testHandler(){
        return  "Welcome to Spring Security.";
    }
    @PostMapping(SIGN_IN)
    public ResponseEntity<UsersDetails> saveUsersDetails(@RequestBody UsersDetails martUser){
        martUser.setPassword(passwordEncoder.encode(martUser.getPassword()));
        UsersDetails user=eleMarDetService.registerUser(martUser);
        return new ResponseEntity<>(user,HttpStatus.CREATED);
    }

    @GetMapping(CUSTOMER_BY_EMAIL)
    @ResponseStatus(HttpStatus.ACCEPTED)
    public ResponseEntity<UsersDetails> getUsersDetailsByEmail(@PathVariable("email") String email){
        return  new ResponseEntity<>(eleMarDetService.getMartUserDetailsByEmail(email),HttpStatus.ACCEPTED);
    }
    @GetMapping(CUSTOMERS)
    public ResponseEntity<List<UsersDetails>> getAllUsersDetailss(){
        return  new ResponseEntity<List<UsersDetails>>(eleMarDetService.getAllMartUserDetails(),HttpStatus.ACCEPTED);
    }
//    when we are providing the username and password in Authenticate --> basic auth
/*      @GetMapping("/signIn")
        public ResponseEntity<String> getLoggedInUserDetailsHandler(Authentication auth){
            UsersDetails user = eleMarDetService.getMartUserDetailsByEmail(auth.getName());
            return new ResponseEntity<>(user.getFirstName()+user.getLastName()+" Logged In Successfully!!!",HttpStatus.ACCEPTED);
        }
*/

    @PostMapping(LOGIN)
    public Response<LoginResponse> getLoggedInUserDetailsHandler(@RequestBody LoginBean loginBean, HttpServletRequest request, HttpServletResponse response) {
        try {
            log.info("Initializing user authentication process for sign-in.");
            Authentication auth = authManager.authenticate(new UsernamePasswordAuthenticationToken(loginBean.getUsername(), loginBean.getPassword()));
            log.info("Authenticated User have following authorities: {}",auth.getAuthorities());
            String jwtToken=jwtTokenGeneratorFilter.tokenGenerator(auth);
            response.setHeader(Constants.AUTHORIZATION.getValue(), jwtToken);
            log.info("Authentication token successfully set to the header for the authenticated user: {}", auth.getName());
            LoginResponse loginResponse=new LoginResponse();
            loginResponse.setAuthenticated(auth.getName()+"Authenticated SuccessFully!!!");
            loginResponse.setJwtToken(jwtToken);
            return new Response(loginResponse, HttpStatus.ACCEPTED, HttpStatus.ACCEPTED.value());
        } catch (AuthenticationException exc) {
            response.setStatus(HttpStatus.UNAUTHORIZED.value());
            return new Response("Authentication Failed!!!", HttpStatus.UNAUTHORIZED, HttpStatus.UNAUTHORIZED.value());
        }
    }

    @PostMapping(CONTACT)
    public String postDemo1(){
        return  "Not harmful Post operation";
    }
    @PutMapping(NOTICE)
    public String postDemo2(){
        return  "Not harmful Put operation";
    }

    @PostMapping(WRITE)
    public String postDemo3(){
        return  "harmful Post operation";
    }

    @GetMapping(USER_DETAILS)
    public ResponseEntity<UserDetails> getUserDetail(String username){
        return  new ResponseEntity<>(userService.loadUserByUsername(username),HttpStatus.OK);
    }
}
