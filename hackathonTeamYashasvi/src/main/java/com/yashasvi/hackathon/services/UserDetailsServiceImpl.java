package com.yashasvi.hackathon.services;

import com.yashasvi.hackathon.domain.ROLE;
import com.yashasvi.hackathon.domain.UsersDetails;
import com.yashasvi.hackathon.exception.UsersDetailsCredentialNotFoundException;
import com.yashasvi.hackathon.repository.UsersDetailsRepository;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.userdetails.User;
import org.springframework.security.core.userdetails.UserDetails;
import org.springframework.security.core.userdetails.UserDetailsService;
import org.springframework.security.core.userdetails.UsernameNotFoundException;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;

@Slf4j
@Service
public final class UserDetailsServiceImpl  implements UserDetailsService {
    @Autowired(required = true)
    private UsersDetailsRepository userRepo;

    @Override
    public UserDetails loadUserByUsername(String username) throws UsernameNotFoundException {
        log.info("Initiating retrieval of user details from the database for authentication object with username: {}", username);
        UsersDetails userDetail= userRepo.findByEmail(username).orElseThrow(()->{
            log.error("Failed to retrieve user details for login. No user found with the username: '{}'", username);
            throw new UsersDetailsCredentialNotFoundException("Invalid Credentials either username or password is wrong!!!");
        } );
        log.info("User Object returned for Authentication Manager method.");
        return new User(userDetail.getEmail(),userDetail.getPassword(),getAuthorities(userDetail.getRole()));
    }
    private List<GrantedAuthority> getAuthorities(String role){
        List<GrantedAuthority> grantedAuthorities= new ArrayList<>();
            grantedAuthorities.add(new SimpleGrantedAuthority(ROLE.PREFIX.getName()+role.toUpperCase()));
        return grantedAuthorities;
    }
}
