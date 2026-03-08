 export interface GeminiResponse {
  "event_name":string
  "category": string,
  "description": string,
  "options": string[],
  "event_start": string,
  "closing_date": string,
  "resolution_date": string,
  "verification_source": string,
  "trending_reason": string
}


export interface GeminiResolveResponse{
  "result": string,
  "confidence": number,
  "source_url": string
}


export interface SignupNewUserResponse {
  kind: string;
  idToken: string; // JWT token for Firestore authentication
  refreshToken: string;
  expiresIn: string; // Token expiration time in seconds
  localId: string; // Anonymous user ID
}



export interface IsDuplicate{
  is_duplicate: boolean
}


export interface InputType{

    question: string
    resolutionTime: string

}
