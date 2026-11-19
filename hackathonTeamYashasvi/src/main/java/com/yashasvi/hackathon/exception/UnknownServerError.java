package com.yashasvi.hackathon.exception;

import lombok.NoArgsConstructor;

@NoArgsConstructor
public class UnknownServerError extends  RuntimeException{
    public  UnknownServerError(String message){
        super(message);
    }
}
