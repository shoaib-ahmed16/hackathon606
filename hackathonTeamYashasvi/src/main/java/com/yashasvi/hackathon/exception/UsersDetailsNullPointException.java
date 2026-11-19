package com.yashasvi.hackathon.exception;

import lombok.NoArgsConstructor;

@NoArgsConstructor
public class UsersDetailsNullPointException extends RuntimeException {

   public UsersDetailsNullPointException(String message){
       super(message);
   }
}
