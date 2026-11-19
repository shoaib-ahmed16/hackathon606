package com.yashasvi.hackathon.services;

import com.yashasvi.hackathon.domain.UsersDetails;
import com.yashasvi.hackathon.domain.ROLE;
import com.yashasvi.hackathon.exception.DatabaseUnknownServerError;
import com.yashasvi.hackathon.exception.UsersDetailsException;
import com.yashasvi.hackathon.repository.UsersDetailsRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Service;

import java.util.List;

@Slf4j
@Service(value = "usersDetailsService")
public final class UsersDetailsServiceImpl implements  UsersDetailsService {

    @Autowired
    private UsersDetailsRepository userRepo;

    @Override
    public UsersDetails registerUser(UsersDetails martUser) {
        log.info("Initializing the process to save user details to the database for email: {}", martUser.getEmail());
        log.info("Saving UsersDetails to the database.");
        // Self-registration always yields a regular user; never trust a client-supplied role.
        martUser.setRole(ROLE.USER.getName());
        userRepo.save(martUser);
        log.info("UsersDetails successfully saved to the database.");
        return martUser;
    }

    @Override
    public UsersDetails getMartUserDetailsByEmail(String email) throws UsersDetailsException {
        log.info("Initiating retrieval of user details from the database with email: {}", email);
        UsersDetails userDetail= userRepo.findByEmail(email).orElseThrow(()->{
            log.error("Failed to retrieve user details. No user found with the email: '{}'", email);
            throw new UsersDetailsException("No record found of any user User with email :"+email);
        } );
        log.info("Returning the user details from the database with email: {}", email);
        return  userDetail;
    }

    @Override
    public List<UsersDetails> getAllMartUserDetails() throws UsersDetailsException,DatabaseUnknownServerError {
        log.info("Initiating retrieval of all user details from the database.");
        List<UsersDetails> martUsers = userRepo.findAll();
        log.info("Returning the all user details from the database.");
        return  martUsers;
    }
}
