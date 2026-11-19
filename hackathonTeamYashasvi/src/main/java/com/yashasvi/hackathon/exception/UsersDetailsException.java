package com.yashasvi.hackathon.exception;

import lombok.NoArgsConstructor;

@NoArgsConstructor
public class UsersDetailsException extends  RuntimeException{
    public UsersDetailsException(String message){
        super(message);
    }
}
