package com.yashasvi.hackathon.services;

import com.yashasvi.hackathon.domain.UsersDetails;
import com.yashasvi.hackathon.exception.UsersDetailsException;

import java.util.List;

public sealed interface UsersDetailsService permits UsersDetailsServiceImpl  {

    UsersDetails registerUser(UsersDetails martUser);

    UsersDetails getMartUserDetailsByEmail(String email)throws UsersDetailsException;

    List<UsersDetails> getAllMartUserDetails()throws UsersDetailsException;

}
