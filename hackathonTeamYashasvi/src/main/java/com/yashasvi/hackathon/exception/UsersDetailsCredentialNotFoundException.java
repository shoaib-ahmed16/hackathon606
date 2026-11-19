package com.yashasvi.hackathon.exception;

import lombok.NoArgsConstructor;

@NoArgsConstructor
public class UsersDetailsCredentialNotFoundException extends RuntimeException{
    public UsersDetailsCredentialNotFoundException(String message){
        super(message);
    }
}
