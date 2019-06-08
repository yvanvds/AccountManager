using AccountApi.SS;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Smartschool
{
    public static class Connector
    {
        internal static V3Service service;
        internal static String password;
        internal static ILog Log;

        public static string[] DiscardSubgroups = new string[] { };

        public static string StudentPath { get; set; }
        public static string StaffPath { get; set; }

        public static string[] StudentGrade = new string[] { };
        public static string[] StudentYear = new string[] { };

        public static void Init(string site, string password, ILog log = null)
        {
            try
            {
                service = new V3Service
                {
                    Url = "https://" + site + ".smartschool.be/Webservices/V3"
                };

                Connector.password = password;
                Log = log;

                Error.GetCodes();
            }
            catch (Exception e)
            {
                if (log != null) log.AddError(Origin.Smartschool, e.Message);
            }

        }


        public static void Disconnect()
        {
            service?.Dispose();
        }


    }
}


//Not needed now //mixed addCourseStudents(string $accesscode, string $coursename, string $coursedesc, string $groupIds)
//Not needed now //mixed addCourseTeacher(string $accesscode, string $coursename, string $coursedesc, string $internnummer, string $userlist)
//Not needed now //mixed changeGroupOwners(string $accesscode, $code, $userlist)
//Not needed now //string checkStatus(string $accesscode, string $uuid)
//Not needed now //mixed deactivateTwoFactorAuthentication(string $accesscode, string $userIdentifier, integer $accountType)
//Not needed now //mixed getAbsents(string $accesscode, string $userIdentifier, string $schoolYear)
//Not needed now //mixed getAbsentsByDate(string $accesscode, string $date)
//Not needed now //mixed getAbsentsWithAliasByDate(string $accesscode, string $date)
//Not needed now //mixed getAccountPhoto(string $accesscode, string $userIdentifier)
//Not needed now //string getClassList(string $accesscode)
//Not needed now //string getClassListJson(string $accesscode)
//Not needed now //mixed getClassTeachers(string $accesscode, boolean $getAllOwners)
//Not needed now //mixed getSkoreClassTeacherCourseRelation(string $accesscode)
//Not needed now //string getStudentCareer(string $accesscode, string $userIdentifier)
//Not needed now //mixed getUserDetailsByNumber(string $accesscode, string $number)
//Not needed now //mixed getUserDetailsByUsername(string $accesscode, string $username)
//Not needed now //mixed getUserOfficialClass(string $accesscode, string $userIdentifier, string $date)
//Not needed now //mixed replaceInum(string $accesscode, string $oldInum, string $newInum)
//Not needed now //mixed saveClassList(string $accesscode, string $serializedList)
//Not needed now //mixed saveClassListJson(string $accesscode, string $jsonList)
//Not needed now //mixed saveSignature(string $accesscode, string $userIdentifier, integer $accountType, string $signature)
//Not needed now //mixed saveUserParameter(string $accesscode, string $userIdentifier, string $paramName, string $paramValue)
//Not needed now //mixed saveUserToClasses(string $accesscode, string $userIdentifier, string $csvList)
//Not needed now //mixed sendMsg(string $accesscode, string $userIdentifier, string $title, string $body, string $senderIdentifier, mixed $attachments, [integer $coaccount = 0], boolean $copyToLVS = false)
//Not needed now //mixed setAccountPhoto(string $accesscode, string $userIdentifier, string $photo)
//Not needed now //string startSkoreSync(string $accesscode)