package com.yashasvi.hackathon.exception;

import lombok.NoArgsConstructor;

@NoArgsConstructor
public class UsersDetailsAuthenticationFailException extends RuntimeException{

    public UsersDetailsAuthenticationFailException(String message){
        super(message);
    }
}
